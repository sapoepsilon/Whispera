// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// One read of a session log: its entries, and the byte offsets to read on from.
public struct SessionPage: Equatable, Sendable {
    public var entries: [SessionEntry]
    /// The newest title among the lines read.
    public var title: String?
    /// The offset of the first line read.
    public var start: Int
    /// Just past the last complete line read: where the next forward read starts.
    public var end: Int
    /// There are lines before `start` this page did not read.
    public var hasEarlier: Bool
    /// A forward read stopped at its limit before the end of the file.
    public var hasMore: Bool
    /// The file's size when it was read.
    public var size: Int
}

public enum SessionLogError: Error, Equatable {
    /// The offset is past the end of the file or not at a line start: the file was
    /// replaced or truncated, so the reader starts over.
    case badOffset
    case unreadable
}

/// Reads a JSONL session log in pages: forward from an offset (what was appended since
/// the last read) or backward from the end or an offset (the newest entries first, then
/// earlier ones). Only complete lines are read, so a line Claude Code or Codex is still
/// writing waits for the next read. Lines longer than `SessionLogLimits.line` are skipped.
public enum SessionLog {
    static let chunk = 1 << 20

    public static func read(_ url: URL, harness: SessionHarness, since: Int? = nil, before: Int? = nil,
                            limit: Int = 300, maxScan: Int = 64 << 20, sidechain: Bool = false) throws -> SessionPage {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SessionLogError.unreadable }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let reader: any SessionLogReader
        switch harness {
        case .codex: reader = CodexSessionReader(legacyEvents: !hasItemEvents(handle, size: size))
        case .claude: reader = ClaudeSessionReader(sidechain: sidechain)
        case .omp: reader = OmpSessionReader()
        }
        let limit = max(1, limit)
        if let since {
            return try forward(handle, reader: reader, from: since, size: size, limit: limit, maxScan: maxScan)
        }
        return try backward(handle, reader: reader, until: before ?? size, size: size, limit: limit, maxScan: maxScan)
    }

    // MARK: Forward

    private static func forward(_ handle: FileHandle, reader: any SessionLogReader, from offset: Int, size: Int,
                                limit: Int, maxScan: Int) throws -> SessionPage {
        guard offset >= 0, offset <= size else { throw SessionLogError.badOffset }
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset - 1))
            guard handle.readData(ofLength: 1) == Data([0x0A]) else { throw SessionLogError.badOffset }
        }
        try handle.seek(toOffset: UInt64(offset))
        var entries: [SessionEntry] = []
        var title: String?
        var pending: [UInt8] = []
        var skipping = false
        var lineStart = offset
        var end = offset
        var position = offset
        var hasMore = false
        reading: while position < size {
            let data = [UInt8](handle.readData(ofLength: min(chunk, size - position)))
            guard !data.isEmpty else { break }
            let base = position
            position += data.count
            var cursor = 0
            while let newline = data[cursor...].firstIndex(of: 0x0A) {
                if !skipping {
                    pending += data[cursor..<newline]
                    if pending.count <= SessionLogLimits.line, let line = parse(pending) {
                        title = reader.title(line: line) ?? title
                        entries += reader.entries(line: line, offset: lineStart)
                    }
                }
                pending.removeAll(keepingCapacity: true)
                skipping = false
                end = base + newline + 1
                lineStart = end
                cursor = newline + 1
                if entries.count >= limit || end - offset >= maxScan {
                    hasMore = end < size
                    break reading
                }
            }
            if !skipping {
                pending += data[cursor...]
                if pending.count > SessionLogLimits.line { skipping = true; pending.removeAll() }
            }
        }
        return SessionPage(entries: entries, title: title, start: offset, end: end, hasEarlier: offset > 0,
                           hasMore: hasMore, size: size)
    }

    // MARK: Backward

    private static func backward(_ handle: FileHandle, reader: any SessionLogReader, until requested: Int, size: Int,
                                 limit: Int, maxScan: Int) throws -> SessionPage {
        guard requested >= 0, requested <= size else { throw SessionLogError.badOffset }
        // Stop at the last complete line: the one being written is read next time.
        let end = try lastNewline(handle, before: requested).map { $0 + 1 } ?? 0
        var window = end
        var carry: [UInt8] = []
        var groups: [[SessionEntry]] = []
        var count = 0
        var start = end
        var scanned = 0
        var title: String?
        func process(_ bytes: ArraySlice<UInt8>, at offset: Int) {
            start = offset
            guard !bytes.isEmpty, bytes.count <= SessionLogLimits.line, let line = parse(bytes) else { return }
            if title == nil { title = reader.title(line: line) }
            let entries = reader.entries(line: line, offset: offset)
            if !entries.isEmpty { groups.append(entries); count += entries.count }
        }
        scanning: while window > 0, scanned < maxScan {
            let from = max(0, window - chunk)
            try handle.seek(toOffset: UInt64(from))
            let data = [UInt8](handle.readData(ofLength: window - from)) + carry
            scanned += window - from
            var segmentEnd = data.count
            while let newline = data[..<segmentEnd].lastIndex(of: 0x0A) {
                process(data[(newline + 1)..<segmentEnd], at: from + newline + 1)
                segmentEnd = newline
                if count >= limit { break scanning }
            }
            if from == 0 {
                process(data[..<segmentEnd], at: 0)
                break
            }
            if segmentEnd > SessionLogLimits.line {
                // An overlong line: skip back to the newline before it.
                guard let skip = try lastNewline(handle, before: from) else { start = 0; break }
                carry = []
                window = skip + 1
                start = window
            } else {
                carry = Array(data[..<segmentEnd])
                window = from
            }
        }
        return SessionPage(entries: groups.reversed().flatMap { $0 }, title: title, start: start, end: end,
                           hasEarlier: start > 0, hasMore: false, size: size)
    }

    /// The offset of the last newline before `offset`, if any.
    private static func lastNewline(_ handle: FileHandle, before offset: Int) throws -> Int? {
        var window = offset
        while window > 0 {
            let from = max(0, window - chunk)
            try handle.seek(toOffset: UInt64(from))
            let data = handle.readData(ofLength: window - from)
            if let index = data.lastIndex(of: 0x0A) { return from + (index - data.startIndex) }
            window = from
        }
        return nil
    }

    private static func parse<Bytes: Collection>(_ bytes: Bytes) -> [String: Any]? where Bytes.Element == UInt8 {
        guard !bytes.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }

    /// Whether a Codex log has `item_completed` events (current Codex) in its first
    /// megabytes: older logs are read from their legacy events instead.
    static func hasItemEvents(_ handle: FileHandle, size: Int) -> Bool {
        guard (try? handle.seek(toOffset: 0)) != nil else { return true }
        let data = handle.readData(ofLength: min(size, 8 << 20))
        return data.range(of: Data("\"item_completed\"".utf8)) != nil
    }
}
