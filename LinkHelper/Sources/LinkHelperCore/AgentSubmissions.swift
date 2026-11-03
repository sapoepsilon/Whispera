import CryptoKit
import Foundation
import ImageIO

/// Private image and file uploads and durable delivery receipts, scoped to each authenticated
/// phone. No path comes from the phone: a file keeps only a sanitized form of its name, inside
/// a folder named by its upload ID. A pending receipt is written before the
/// terminal write, so a lost response/restart cannot silently send the same message twice.
final class AgentSubmissions: @unchecked Sendable {
    private let directory: URL
    /// Each phone's folder has a lock of its own, held only for file work (never for ssh or the
    /// terminal), so one phone's slow copy never stalls another phone. A submission also holds
    /// its own id's lock for its whole run: a retry of the same message waits for the first.
    private let locks = NSLock()
    private var deviceLocks: [String: NSLock] = [:]
    private var submissionLocks: [String: (lock: NSLock, users: Int)] = [:]
    /// The storage quota spans every phone: its check and the write it allows are one step.
    private let quotaLock = NSLock()
    private var sweeper: DispatchSourceTimer?
    private static let maxImage = 1_048_576
    /// Refusals that come before anything reaches the terminal: the receipt goes, so the same
    /// message retried later is a fresh delivery rather than "delivery unknown".
    static let nothingSent: Set<String> = ["agent_blocked", "agent_not_ready", "not_found", "bad_request"]
    private static let quota = 128 * 1024 * 1024
    /// Any type: crash reports, logs, long pasted text, PDFs, archives.
    static let maxFile = 25 * 1024 * 1024
    static let maxFiles = 8
    /// The phone's own text; images and files add their paths after it.
    static let maxText = 16000
    static let maxDelivered = 20000
    static let filesMarker = "Attached files (open these files to read):"
    /// An upload that has not grown for this long was abandoned (the phone left or cancelled).
    static let partialAge: TimeInterval = 3600
    /// Receipts and finished uploads are kept this long.
    static let keepFor: TimeInterval = 7 * 86400
    static let sweepInterval: TimeInterval = 15 * 60

    enum UploadKind: String { case image, file }

    init(stateDirectory: String) {
        directory = URL(fileURLWithPath: stateDirectory).appendingPathComponent("submissions")
    }

    deinit { sweeper?.cancel() }

    /// Sweeps abandoned uploads every `interval`, whether or not new ones arrive; the first
    /// sweep runs shortly after start.
    func startSweeping(every interval: TimeInterval = sweepInterval, firstAfter: TimeInterval = 30,
                       onSweep: ((Int, Int) -> Void)? = nil) {
        locks.lock(); defer { locks.unlock() }
        guard sweeper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.submissions.sweep", qos: .utility))
        timer.schedule(deadline: .now() + firstAfter, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (partials, expired) = self.sweep()
            if partials + expired > 0 { onSweep?(partials, expired) }
        }
        timer.resume()
        sweeper = timer
    }

    func stopSweeping() {
        locks.lock(); defer { locks.unlock() }
        sweeper?.cancel()
        sweeper = nil
    }

    private func withDevice<T>(_ device: String, _ body: () throws -> T) rethrows -> T {
        locks.lock()
        let lock = deviceLocks[device] ?? NSLock()
        deviceLocks[device] = lock
        locks.unlock()
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func withSubmission<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        locks.lock()
        var entry = submissionLocks[key] ?? (NSLock(), 0)
        entry.users += 1
        submissionLocks[key] = entry
        locks.unlock()
        entry.lock.lock()
        defer {
            entry.lock.unlock()
            locks.lock()
            if let current = submissionLocks[key] {
                if current.users <= 1 { submissionLocks[key] = nil } else { submissionLocks[key] = (current.lock, current.users - 1) }
            }
            locks.unlock()
        }
        return try body()
    }

    private func phoneDirectory(_ device: String) throws -> URL {
        let url = directory.appendingPathComponent(device)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return url
    }

    private func checkedID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else {
            throw APIError(400, "bad_request", "image and submission ids must be UUIDs")
        }
        return uuid.uuidString.lowercased()
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Appends `chunk` at `offset` of `url`, or checks that a repeated chunk matches what is
    /// there. Never rewrites the bytes already received. Answers the size afterwards.
    private func appendChunk(_ chunk: Data, at offset: Int, to url: URL, conflict: APIError) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        if offset == size {
            try withQuota(adding: chunk.count) { try handle.write(contentsOf: chunk) }
        } else {
            guard offset + chunk.count <= size else { throw conflict }
            try handle.seek(toOffset: UInt64(offset))
            guard try handle.read(upToCount: chunk.count) == chunk else { throw conflict }
        }
        return Int(try handle.seekToEnd())
    }

    func upload(_ id: String, device: String, request: [String: Any]) throws -> [String: Any] {
        let id = try checkedID(id)
        guard let mime = request["mime_type"] as? String, ["image/jpeg", "image/png"].contains(mime),
              let total = WireJSON.strictInt(request["total_bytes"]), (1...Self.maxImage).contains(total),
              let offset = WireJSON.strictInt(request["offset"]), offset >= 0,
              let encoded = request["data"] as? String, encoded.utf8.count <= 32768,
              let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 24 * 1024,
              offset <= total - chunk.count else {
            throw APIError(400, "bad_request", "invalid image chunk (JPEG/PNG, at most 1 MB)")
        }
        return try withDevice(device) {
            let fm = FileManager.default
            let folder = try phoneDirectory(device)
            let image = folder.appendingPathComponent(id + (mime == "image/jpeg" ? ".jpg" : ".png"))
            let meta = folder.appendingPathComponent(id + ".image.json")
            if let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved) {
                guard object["total"] as? Int == total, object["mime"] as? String == mime else {
                    throw APIError(409, "image_conflict", "upload id already belongs to another image")
                }
            } else {
                guard offset == 0 else { throw APIError(409, "image_offset", "restart this image upload") }
                try withQuota(adding: chunk.count) {}
                try write(Data(), to: image)
                try write(WireJSON.encode(["total": total, "mime": mime]), to: meta)
            }
            // Aborted (or swept) meanwhile: the phone starts over.
            guard fm.fileExists(atPath: image.path) else { throw APIError(409, "image_offset", "restart this image upload") }
            let received = try appendChunk(chunk, at: offset, to: image,
                                           conflict: APIError(409, "image_offset", "image chunk conflicts with the upload"))
            if received == total {
                guard let data = fm.contents(atPath: image.path),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source) as String?,
                      type == (mime == "image/jpeg" ? "public.jpeg" : "public.png"),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                      width > 0, height > 0, width <= 4096, height <= 4096,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    try? fm.removeItem(at: image)
                    try? fm.removeItem(at: meta)
                    throw APIError(400, "invalid_image", "that file is not a supported image")
                }
            }
            return ["id": id, "received_bytes": received, "complete": received == total]
        }
    }

    /// One chunk of a file of any type. Chunks arrive in order; a repeated chunk that matches
    /// the bytes already saved is accepted without appending. Bytes are appended in place, so a
    /// 25 MB upload never rewrites what it already holds.
    func uploadFile(_ id: String, device: String, request: [String: Any]) throws -> [String: Any] {
        let id = try checkedID(id)
        guard let rawName = request["name"] as? String, let name = Self.safeFileName(rawName),
              let total = WireJSON.strictInt(request["total_bytes"]), (1...Self.maxFile).contains(total),
              let offset = WireJSON.strictInt(request["offset"]), offset >= 0,
              let encoded = request["data"] as? String, encoded.utf8.count <= 32768,
              let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 24 * 1024,
              offset <= total - chunk.count else {
            throw APIError(400, "bad_request", "invalid file chunk (a name, at most 25 MB)")
        }
        return try withDevice(device) {
            let fm = FileManager.default
            let folder = try phoneDirectory(device)
            let meta = folder.appendingPathComponent(id + ".file.json")
            let files = folder.appendingPathComponent("files", isDirectory: true)
            let holder = files.appendingPathComponent(id, isDirectory: true)
            let file = holder.appendingPathComponent(name)
            if let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved) {
                guard object["total"] as? Int == total, object["name"] as? String == name else {
                    throw APIError(409, "file_conflict", "upload id already belongs to another file")
                }
            } else {
                guard offset == 0 else { throw APIError(409, "file_offset", "restart this file upload") }
                try withQuota(adding: chunk.count) {}
                for url in [files, holder] {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
                try write(Data(), to: file)
                try write(WireJSON.encode(["total": total, "name": name]), to: meta)
            }
            guard fm.fileExists(atPath: file.path) else { throw APIError(409, "file_offset", "restart this file upload") }
            let received = try appendChunk(chunk, at: offset, to: file,
                                           conflict: APIError(409, "file_offset", "file chunk conflicts with the upload"))
            return ["id": id, "name": name, "received_bytes": received, "complete": received == total]
        }
    }

    /// `DELETE /v1/images/{id}` and `/v1/files/{id}`: the phone gave up on an upload (or on the
    /// message it was for). Only the calling phone's own folder is looked in; idempotent.
    func abort(_ id: String, kind: UploadKind, device: String) throws -> [String: Any] {
        let id = try checkedID(id)
        return try withDevice(device) {
            let deleted = try removeUpload(id: id, kind: kind, folder: directory.appendingPathComponent(device))
            return ["id": id, "deleted": deleted]
        }
    }

    /// A finished file upload of this phone, for a route that reads it (speech by file). Only
    /// the calling phone's own folder is looked in, so another phone's upload id is "not found".
    func finishedFile(_ id: String, device: String) throws -> (url: URL, name: String, size: Int) {
        let id = try checkedID(id)
        return try withDevice(device) {
            let fm = FileManager.default
            let folder = directory.appendingPathComponent(device)
            let meta = folder.appendingPathComponent(id + ".file.json")
            guard let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved),
                  let name = object["name"] as? String, Self.safeFileName(name) == name,
                  let total = object["total"] as? Int else {
                throw APIError(404, "file_not_found", "No uploaded file with that id. Upload the audio again.")
            }
            let file = folder.appendingPathComponent("files").appendingPathComponent(id).appendingPathComponent(name)
            guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size == total else {
                throw APIError(400, "file_incomplete", "The audio hasn't finished uploading. Try again.")
            }
            return (file, name, size)
        }
    }

    /// Removes uploads that stopped growing `partialAge` ago before they were complete, and
    /// anything (receipts, finished uploads) older than `keepFor`. Answers how many of each.
    @discardableResult
    func sweep(now: Date = Date()) -> (partials: Int, expired: Int) {
        let fm = FileManager.default
        let devices = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var partials = 0, expired = 0
        for folder in devices {
            withDevice(folder.lastPathComponent) {
                for meta in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    let name = meta.lastPathComponent
                    let kind: UploadKind
                    if name.hasSuffix(".image.json") { kind = .image } else if name.hasSuffix(".file.json") { kind = .file } else { continue }
                    let id = String(name.dropLast(kind == .image ? 11 : 10))
                    guard let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved),
                          let total = object["total"] as? Int else { continue }
                    let data: URL?
                    switch kind {
                    case .image:
                        data = (object["mime"] as? String).map { folder.appendingPathComponent(id + ($0 == "image/jpeg" ? ".jpg" : ".png")) }
                    case .file:
                        data = (object["name"] as? String).map {
                            folder.appendingPathComponent("files").appendingPathComponent(id).appendingPathComponent($0)
                        }
                    }
                    let attributes = data.flatMap { try? fm.attributesOfItem(atPath: $0.path) }
                    let size = attributes?[.size] as? Int ?? 0
                    let touched = attributes?[.modificationDate] as? Date
                        ?? (try? fm.attributesOfItem(atPath: meta.path))?[.modificationDate] as? Date ?? .distantPast
                    guard size < total, now.timeIntervalSince(touched) >= Self.partialAge else { continue }
                    _ = try? removeUpload(id: id, kind: kind, folder: folder)
                    partials += 1
                }
                guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
                for case let file as URL in entries {
                    guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true, let date = values.contentModificationDate,
                          now.timeIntervalSince(date) >= Self.keepFor else { continue }
                    try? fm.removeItem(at: file)
                    expired += 1
                }
                let files = folder.appendingPathComponent("files")
                for holder in (try? fm.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? []
                where ((try? fm.contentsOfDirectory(atPath: holder.path)) ?? ["x"]).isEmpty {
                    try? fm.removeItem(at: holder)
                }
            }
        }
        return (partials, expired)
    }

    /// An upload's meta and bytes, under the phone's lock; true when there was something.
    private func removeUpload(id: String, kind: UploadKind, folder: URL) throws -> Bool {
        let fm = FileManager.default
        let targets: [URL] = kind == .image
            ? [id + ".image.json", id + ".jpg", id + ".png"].map { folder.appendingPathComponent($0) }
            : [folder.appendingPathComponent(id + ".file.json"), folder.appendingPathComponent("files").appendingPathComponent(id)]
        var removed = false
        for url in targets where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            removed = true
        }
        return removed
    }

    /// The phone's file name, reduced to characters that are safe in a path, a prompt and a
    /// remote `scp` destination. Keeps the extension; never empty, hidden or a traversal.
    static func safeFileName(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 1024, !raw.contains("\0") else { return nil }
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        var name = ""
        for scalar in base.unicodeScalars {
            let safe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-+@".unicodeScalars.contains(scalar))
            if safe { name.unicodeScalars.append(scalar) } else if !name.hasSuffix("_") { name += "_" }
        }
        while let last = name.last, "._".contains(last) { name.removeLast() }
        let dot = name.lastIndex(of: ".")
        var stem = dot.map { String(name[..<$0]) } ?? name
        var ext = dot.map { String(name[name.index(after: $0)...]) } ?? ""
        if ext.count > 16 || ext.contains("_") { stem = name; ext = "" }
        while let first = stem.first, ".-_".contains(first) { stem.removeFirst() }
        while let last = stem.last, "._-".contains(last) { stem.removeLast() }
        if stem.isEmpty { stem = "file" }
        if stem.count > 100 { stem = String(stem.prefix(100)) }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Runs `write` only when `adding` more bytes keep every phone's uploads under the quota;
    /// the count and the write are one step, so two phones can't both take the last room.
    private func withQuota(adding: Int, _ write: () throws -> Void) throws {
        quotaLock.lock(); defer { quotaLock.unlock() }
        var bytes = 0
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in files { bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        }
        guard bytes <= Self.quota - adding else {
            throw APIError(413, "image_storage_full", "Mac attachment storage is full; try again later")
        }
        try write()
    }

    /// Delivers a message once. Steps: the receipt check and the attachment lookup (under the
    /// phone's lock), the copy to a remote machine (`prepare`, no lock: ssh and scp are slow),
    /// then the pending receipt and the terminal write. A cancelled request stops between steps
    /// and inside `prepare`; the terminal write itself always finishes, so its receipt is true.
    func submit(_ id: String, device: String, agent: String, text: String, images: [String], files: [String] = [],
                prepare: ([String]) throws -> [String], send: (String) throws -> [String: Any]) throws -> [String: Any] {
        let id = try checkedID(id)
        guard images.count <= 4 else { throw APIError(400, "bad_request", "attach at most four images") }
        guard files.count <= Self.maxFiles else { throw APIError(400, "bad_request", "attach at most \(Self.maxFiles) files") }
        return try withSubmission(device + "/" + id) {
            try CancelToken.checkCurrent()
            // Files join the digest only when there are some: a receipt saved before file uploads
            // still matches its retry.
            var signed: [String: Any] = ["agent": agent, "text": text, "images": images]
            if !files.isEmpty { signed["files"] = files }
            let digest = LinkCryptoDigest.hash(WireJSON.encode(signed))
            let looked: (receipt: URL, answer: [String: Any]?, paths: [String]) = try withDevice(device) {
                let fm = FileManager.default
                let folder = try phoneDirectory(device)
                let receipt = folder.appendingPathComponent(id + ".receipt.json")
                if let saved = fm.contents(atPath: receipt.path), let object = WireJSON.decodeObject(saved) {
                    guard object["digest"] as? String == digest else {
                        throw APIError(409, "submission_conflict", "submission id already belongs to another message")
                    }
                    if let answer = object["answer"] as? [String: Any] { return (receipt, answer, []) }
                    throw APIError(409, "delivery_unknown", "The Mac may have sent this message, but its receipt was interrupted. Check the conversation before sending it again.")
                }
                var paths: [String] = []
                for imageID in images {
                    let imageID = try checkedID(imageID)
                    let meta = folder.appendingPathComponent(imageID + ".image.json")
                    guard let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved),
                          let mime = object["mime"] as? String, let total = object["total"] as? Int else {
                        throw APIError(400, "image_incomplete", "An image hasn't finished uploading. Try sending again.")
                    }
                    let image = folder.appendingPathComponent(imageID + (mime == "image/jpeg" ? ".jpg" : ".png"))
                    guard let size = (try? fm.attributesOfItem(atPath: image.path))?[.size] as? Int, size == total else {
                        throw APIError(400, "image_incomplete", "An image hasn't finished uploading. Try sending again.")
                    }
                    paths.append(image.path)
                }
                for fileID in files {
                    let fileID = try checkedID(fileID)
                    let meta = folder.appendingPathComponent(fileID + ".file.json")
                    guard let saved = fm.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved),
                          let name = object["name"] as? String, Self.safeFileName(name) == name, let total = object["total"] as? Int else {
                        throw APIError(400, "file_incomplete", "A file hasn't finished uploading. Try sending again.")
                    }
                    let file = folder.appendingPathComponent("files").appendingPathComponent(fileID).appendingPathComponent(name)
                    guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size == total else {
                        throw APIError(400, "file_incomplete", "A file hasn't finished uploading. Try sending again.")
                    }
                    paths.append(file.path)
                }
                return (receipt, nil, paths)
            }
            if let answer = looked.answer { return answer }
            try CancelToken.checkCurrent()
            let paths = try prepare(looked.paths)
            try CancelToken.checkCurrent()
            let imagePaths = paths.prefix(images.count), filePaths = paths.dropFirst(images.count)
            var delivered = text
            if !imagePaths.isEmpty { delivered += "\n\nAttached images (open these files to view):\n" + imagePaths.joined(separator: "\n") }
            if !filePaths.isEmpty { delivered += "\n\n" + Self.filesMarker + "\n" + filePaths.joined(separator: "\n") }
            guard delivered.unicodeScalars.count <= Self.maxDelivered else { throw APIError(400, "bad_request", "message with attachment references is too long") }
            let receipt = looked.receipt
            try withDevice(device) { try write(WireJSON.encode(["digest": digest]), to: receipt) }
            do {
                let answer = try CancelToken.withoutCancellation { try send(delivered) }
                // If persistence fails after sending, leave the pending receipt to prevent a resend.
                try withDevice(device) { try write(WireJSON.encode(["digest": digest, "answer": answer]), to: receipt) }
                return answer
            } catch let error as APIError where Self.nothingSent.contains(error.code) {
                withDevice(device) { try? FileManager.default.removeItem(at: receipt) }
                throw error
            } catch {
                throw APIError(409, "delivery_unknown", "The Mac may have sent this message but couldn't confirm delivery. Retry this unchanged message to check its receipt, or check the conversation first.")
            }
        }
    }
}

private enum LinkCryptoDigest {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
