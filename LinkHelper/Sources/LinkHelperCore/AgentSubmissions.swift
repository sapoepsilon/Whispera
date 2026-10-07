import CryptoKit
import Foundation
import ImageIO

/// Private image uploads and durable delivery receipts, scoped to each authenticated phone.
/// Neither filenames nor paths come from the phone. A pending receipt is written before the
/// terminal write, so a lost response/restart cannot silently send the same message twice.
final class AgentSubmissions: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private static let maxImage = 1_048_576
    private static let quota = 128 * 1024 * 1024

    init(stateDirectory: String) {
        directory = URL(fileURLWithPath: stateDirectory).appendingPathComponent("submissions")
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

    func upload(_ id: String, device: String, request: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let id = try checkedID(id)
        guard let mime = request["mime_type"] as? String, ["image/jpeg", "image/png"].contains(mime),
              let total = WireJSON.strictInt(request["total_bytes"]), (1...Self.maxImage).contains(total),
              let offset = WireJSON.strictInt(request["offset"]), offset >= 0,
              let encoded = request["data"] as? String, encoded.utf8.count <= 32768,
              let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 24 * 1024,
              offset <= total - chunk.count else {
            throw APIError(400, "bad_request", "invalid image chunk (JPEG/PNG, at most 1 MB)")
        }
        let folder = try phoneDirectory(device)
        let image = folder.appendingPathComponent(id + (mime == "image/jpeg" ? ".jpg" : ".png"))
        let meta = folder.appendingPathComponent(id + ".image.json")
        let previous = FileManager.default.contents(atPath: image.path) ?? Data()
        if let saved = FileManager.default.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved) {
            guard object["total"] as? Int == total, object["mime"] as? String == mime else {
                throw APIError(409, "image_conflict", "upload id already belongs to another image")
            }
        } else {
            guard offset == 0 else { throw APIError(409, "image_offset", "restart this image upload") }
            try enforceQuota(adding: chunk.count)
            try write(WireJSON.encode(["total": total, "mime": mime]), to: meta)
        }
        var data = previous
        if offset == previous.count {
            try enforceQuota(adding: chunk.count)
            data.append(chunk)
        }
        else {
            guard offset + chunk.count <= previous.count,
                  previous.subdata(in: offset..<offset + chunk.count) == chunk else {
                throw APIError(409, "image_offset", "image chunk conflicts with the upload")
            }
        }
        if data.count == total {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  type == (mime == "image/jpeg" ? "public.jpeg" : "public.png"),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                try? FileManager.default.removeItem(at: image)
                try? FileManager.default.removeItem(at: meta)
                throw APIError(400, "invalid_image", "that file is not a supported image")
            }
        }
        try write(data, to: image)
        return ["id": id, "received_bytes": data.count, "complete": data.count == total]
    }

    private func enforceQuota(adding: Int) throws {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var bytes = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let date = values.contentModificationDate, date < Date().addingTimeInterval(-7 * 86400) {
                try? fm.removeItem(at: file)
            } else { bytes += values.fileSize ?? 0 }
        }
        guard bytes <= Self.quota - adding else {
            throw APIError(413, "image_storage_full", "Mac image storage is full; try again later")
        }
    }

    func submit(_ id: String, device: String, agent: String, text: String, images: [String],
                prepare: ([String]) throws -> [String], send: (String) throws -> [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let id = try checkedID(id)
        guard images.count <= 4 else { throw APIError(400, "bad_request", "attach at most four images") }
        let folder = try phoneDirectory(device)
        let receipt = folder.appendingPathComponent(id + ".receipt.json")
        let digest = LinkCryptoDigest.hash(WireJSON.encode(["agent": agent, "text": text, "images": images]))
        if let saved = FileManager.default.contents(atPath: receipt.path), let object = WireJSON.decodeObject(saved) {
            guard object["digest"] as? String == digest else {
                throw APIError(409, "submission_conflict", "submission id already belongs to another message")
            }
            if let answer = object["answer"] as? [String: Any] { return answer }
            throw APIError(409, "delivery_unknown", "The Mac may have sent this message, but its receipt was interrupted. Check the conversation before sending it again.")
        }
        var paths: [String] = []
        for imageID in images {
            let imageID = try checkedID(imageID)
            let meta = folder.appendingPathComponent(imageID + ".image.json")
            guard let saved = FileManager.default.contents(atPath: meta.path), let object = WireJSON.decodeObject(saved),
                  let mime = object["mime"] as? String, let total = object["total"] as? Int,
                  let data = FileManager.default.contents(atPath: folder.appendingPathComponent(imageID + (mime == "image/jpeg" ? ".jpg" : ".png")).path), data.count == total else {
                throw APIError(400, "image_incomplete", "An image hasn't finished uploading. Try sending again.")
            }
            paths.append(folder.appendingPathComponent(imageID + (mime == "image/jpeg" ? ".jpg" : ".png")).path)
        }
        paths = try prepare(paths)
        let delivered = text + (paths.isEmpty ? "" : "\n\nAttached images (open these files to view):\n" + paths.joined(separator: "\n"))
        guard delivered.unicodeScalars.count <= 8000 else { throw APIError(400, "bad_request", "message with image references is too long") }
        try write(WireJSON.encode(["digest": digest]), to: receipt)
        do {
            let answer = try send(delivered)
            // If persistence fails after sending, leave the pending receipt to prevent a resend.
            try write(WireJSON.encode(["digest": digest, "answer": answer]), to: receipt)
            return answer
        } catch let error as APIError where ["agent_blocked", "not_found", "bad_request"].contains(error.code) {
            try? FileManager.default.removeItem(at: receipt)
            throw error
        } catch {
            throw APIError(409, "delivery_unknown", "The Mac may have sent this message but couldn't confirm delivery. Retry this unchanged message to check its receipt, or check the conversation first.")
        }
    }
}

private enum LinkCryptoDigest {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
