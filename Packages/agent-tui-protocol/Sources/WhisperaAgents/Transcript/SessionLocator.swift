// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// Finds the session log of one agent, and only that one. A log is found by the session
/// id the terminal reported for the agent's pane (herdr's `agent_session`), never by a
/// path from a client: the id must look like an id, the file is named after it, and the
/// resolved file must sit inside the harness's own session folder.
public struct SessionLocator: Sendable {
    /// `~/.claude` (or `CLAUDE_CONFIG_DIR`).
    public var claudeHome: URL
    /// `~/.codex` (or `CODEX_HOME`).
    public var codexHome: URL

    public init(claudeHome: URL, codexHome: URL) {
        self.claudeHome = claudeHome
        self.codexHome = codexHome
    }

    /// The homes the harnesses themselves use for this user.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
        func configured(_ key: String) -> URL? {
            guard let value = environment[key], value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value)
        }
        claudeHome = configured("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude")
        codexHome = configured("CODEX_HOME") ?? home.appendingPathComponent(".codex")
    }

    /// UUID-shaped ids only: letters, digits and dashes, 8–64 of them.
    public static func isValidSessionID(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count)
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Claude Code's project folder name for a working directory: every character that is
    /// not a letter or digit becomes `-` (`/private/tmp/a.b` → `-private-tmp-a-b`).
    public static func claudeSlug(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// The spellings of a directory Claude Code may have recorded (`/tmp` is `/private/tmp`).
    static func cwdVariants(_ cwd: String) -> [String] {
        var variants = [cwd]
        if cwd.hasPrefix("/private/") { variants.append(String(cwd.dropFirst("/private".count))) }
        else if ["/tmp", "/var", "/etc"].contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) { variants.append("/private" + cwd) }
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        if !variants.contains(resolved) { variants.append(resolved) }
        return variants
    }

    public func log(_ harness: SessionHarness, sessionID: String, cwd: String?) -> URL? {
        switch harness {
        case .claude: return claudeLog(sessionID: sessionID, cwd: cwd)
        case .codex: return codexLog(sessionID: sessionID)
        }
    }

    /// `~/.claude/projects/<slug of cwd>/<id>.jsonl`; if the agent changed folders, the
    /// one project folder that has the file.
    public func claudeLog(sessionID: String, cwd: String?) -> URL? {
        guard Self.isValidSessionID(sessionID) else { return nil }
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        let name = sessionID + ".jsonl"
        for variant in cwd.map(Self.cwdVariants) ?? [] {
            let candidate = projects.appendingPathComponent(Self.claudeSlug(variant)).appendingPathComponent(name)
            if let file = contained(candidate, in: projects) { return file }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let file = contained(folder.appendingPathComponent(name), in: projects) { return file }
        }
        return nil
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, newest day first.
    public func codexLog(sessionID: String, maxDays: Int = 400) -> URL? {
        guard Self.isValidSessionID(sessionID) else { return nil }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let suffix = "-" + sessionID + ".jsonl"
        var days = 0
        for year in Self.children(sessions).reversed() {
            for month in Self.children(year).reversed() {
                for day in Self.children(month).reversed() {
                    days += 1
                    if days > maxDays { return nil }
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: day.path)) ?? []
                    if let name = names.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(suffix) }),
                       let file = contained(day.appendingPathComponent(name), in: sessions) {
                        return file
                    }
                }
            }
        }
        return nil
    }

    /// The newest Claude Code log for a folder, written to since `after`: for a terminal
    /// that does not report the session id. Nil when there is none.
    public func newestClaudeLog(cwd: String, after: Date? = nil) -> URL? {
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        var best: (URL, Date)?
        for variant in Self.cwdVariants(cwd) {
            let folder = projects.appendingPathComponent(Self.claudeSlug(variant), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate,
                      after.map({ modified >= $0 }) ?? true, contained(file, in: projects) != nil else { continue }
                if best.map({ modified > $0.1 }) ?? true { best = (file, modified) }
            }
        }
        return best?.0
    }

    /// The session id a log file is named after.
    public static func sessionID(of log: URL, harness: SessionHarness) -> String? {
        let name = log.deletingPathExtension().lastPathComponent
        switch harness {
        case .claude: return isValidSessionID(name) ? name : nil
        case .codex:
            // rollout-2026-10-28T01-49-39-<uuid>: the id is the last five dash groups.
            let groups = name.split(separator: "-")
            guard groups.count >= 5 else { return nil }
            let id = groups.suffix(5).joined(separator: "-")
            return isValidSessionID(id) ? id : nil
        }
    }

    /// Codex's thread name from `session_index.jsonl` (its newest row for the id).
    public func codexTitle(sessionID: String, maxBytes: Int = 4 << 20) -> String? {
        guard Self.isValidSessionID(sessionID),
              let handle = try? FileHandle(forReadingFrom: codexHome.appendingPathComponent("session_index.jsonl"))
        else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let from = max(0, size - maxBytes)
        guard (try? handle.seek(toOffset: UInt64(from))) != nil else { return nil }
        let data = handle.readData(ofLength: size - from)
        let needle = Data("\"\(sessionID)\"".utf8)
        var title: String?
        for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  row["id"] as? String == sessionID else { continue }
            title = nonEmpty(row["thread_name"] as? String) ?? title
        }
        return title
    }

    // MARK: Helpers

    private static func children(_ folder: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.allSatisfy(\.isNumber) }.sorted()
        return names.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// The file, if it is a regular file whose real path is inside `root`.
    private func contained(_ file: URL, in root: URL) -> URL? {
        let real = file.resolvingSymlinksInPath()
        let base = root.resolvingSymlinksInPath().path + "/"
        guard real.path.hasPrefix(base),
              (try? real.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return real
    }
}
