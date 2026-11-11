// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// Whether an agent's session log shows a turn still in progress: the owner sent a prompt
/// (or a tool returned) and the harness has not written the end of the turn yet. A turn
/// that stays open while nothing is written is an agent waiting on the owner — a
/// permission dialog or a question — even when its terminal looks idle (Claude Code's
/// full-screen view scrolled up hides the dialog and its title shows idle).
///
/// Claude Code ends every turn with a `system`/`turn_duration` line and writes a tool call
/// that needs approval only once it is answered, so the open turn, not a pending
/// `tool_use`, is the signal. Codex brackets turns with `task_started` and
/// `task_complete`/`turn_aborted`.
public struct SessionTurn: Equatable, Sendable {
    /// A turn started and has not ended.
    public var open: Bool
    /// A tool call the log has no result for yet (the newest one), when the harness wrote it.
    public var pendingTool: SessionTool?
    /// The log's size when read.
    public var size: Int
}

extension SessionLog {
    /// The state of the newest turn, from the last `maxScan` bytes of the log. Nil when the
    /// file can't be read or no turn boundary is in that window.
    public static func turn(_ url: URL, harness: SessionHarness, maxScan: Int = 512 << 10) -> SessionTurn? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let from = max(0, size - maxScan)
        guard (try? handle.seek(toOffset: UInt64(from))) != nil else { return nil }
        var lines = handle.readData(ofLength: size - from).split(separator: 0x0A, omittingEmptySubsequences: true)
        // A window that starts mid-line drops that partial line; the last one may still be written.
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        var open: Bool?
        var tools: [String: SessionTool] = [:]
        var order: [String] = []
        for raw in lines {
            guard raw.count <= SessionLogLimits.line,
                  let line = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            switch harness {
            case .claude: claudeTurn(line, open: &open, tools: &tools, order: &order)
            case .codex: codexTurn(line, open: &open, tools: &tools, order: &order)
            case .omp: ompTurn(line, open: &open, tools: &tools, order: &order)
            }
        }
        guard let open else { return nil }
        let pending = order.reversed().first { tools[$0] != nil }.flatMap { tools[$0] }
        return SessionTurn(open: open, pendingTool: open ? pending : nil, size: size)
    }

    private static func claudeTurn(_ line: [String: Any], open: inout Bool?, tools: inout [String: SessionTool],
                                   order: inout [String]) {
        guard line["isSidechain"] as? Bool != true else { return }
        switch line["type"] as? String {
        case "system" where line["subtype"] as? String == "turn_duration":
            open = false
            tools.removeAll()
        case "user":
            // A compaction's summary is the harness's, not a prompt: compacting an idle
            // session (Claude Code's idle compaction) writes no turn end after it.
            guard line["isMeta"] as? Bool != true, !ClaudeSessionReader.isCompactSummary(line),
                  let message = line["message"] as? [String: Any] else { return }
            if let blocks = message["content"] as? [[String: Any]] {
                var prompt = false
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_result":
                        if let id = block["tool_use_id"] as? String { tools[id] = nil }
                        open = true
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if ClaudeSessionReader.notice(text) == "Interrupted" { open = false; tools.removeAll() }
                        else if ClaudeSessionReader.notice(text) == nil { prompt = true }
                    case "image": prompt = true
                    default: continue
                    }
                }
                if prompt { open = true }
            } else if let text = message["content"] as? String {
                switch ClaudeSessionReader.notice(text) {
                case nil: open = true
                case "Interrupted"?: open = false; tools.removeAll()
                default: return
                }
            }
        case "assistant":
            guard let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_use" {
                if let tool = ClaudeSessionReader.tool(block) { tools[tool.id] = tool; order.append(tool.id) }
            }
        default:
            return
        }
    }

    private static func codexTurn(_ line: [String: Any], open: inout Bool?, tools: inout [String: SessionTool],
                                  order: inout [String]) {
        let payload = line["payload"] as? [String: Any] ?? [:]
        switch (line["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "task_started"?), ("event_msg", "turn_started"?):
            open = true
            tools.removeAll()
        case ("event_msg", "task_complete"?), ("event_msg", "turn_complete"?), ("event_msg", "turn_aborted"?):
            open = false
            tools.removeAll()
        case ("response_item", "function_call"?), ("response_item", "custom_tool_call"?), ("response_item", "local_shell_call"?):
            guard let id = payload["call_id"] as? String else { return }
            let name = payload["name"] as? String ?? "exec"
            tools[id] = SessionTool(id: id, name: name, kind: .of(name), argument: ClaudeSessionReader.oneLine(
                payload["arguments"] as? String ?? payload["input"] as? String ?? ""))
            order.append(id)
        case ("response_item", "function_call_output"?), ("response_item", "custom_tool_call_output"?):
            if let id = payload["call_id"] as? String { tools[id] = nil }
        default:
            return
        }
    }
}

extension SessionLog {
    /// omp: a user message opens a turn, an assistant message that stops for any reason but
    /// `toolUse` ends it, each `toolCall` waits for the `toolResult` naming it, and the
    /// process exiting (`session_exit`) ends whatever was open.
    static func ompTurn(_ line: [String: Any], open: inout Bool?, tools: inout [String: SessionTool], order: inout [String]) {
        switch line["type"] as? String {
        case "message":
            guard let message = line["message"] as? [String: Any] else { return }
            switch message["role"] as? String {
            case "user":
                open = true
            case "assistant":
                for block in OmpSessionReader.blocks(message["content"]) where block["type"] as? String == "toolCall" {
                    if let tool = OmpSessionReader.tool(block) { tools[tool.id] = tool; order.append(tool.id) }
                }
                if let reason = message["stopReason"] as? String, reason != "toolUse" {
                    open = false
                    tools.removeAll()
                } else {
                    open = true
                }
            case "toolResult":
                if let id = message["toolCallId"] as? String { tools[id] = nil }
                open = true
            default:
                return
            }
        case "custom" where line["customType"] as? String == "session_exit":
            open = false
            tools.removeAll()
        default:
            return
        }
    }
}

extension SessionLocator {
    /// The newest Codex rollout started in `cwd` and written to since `after`: for an agent
    /// whose terminal has not reported its session id (Codex creates the rollout with its
    /// first prompt). Only the last few days' folders are looked at.
    public func newestCodexLog(cwd: String, after: Date, days: Int = 3) -> URL? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let wanted = Set(Self.cwdVariants(cwd))
        var best: (URL, Date)?
        var seen = 0
        let calendar = Calendar(identifier: .gregorian)
        for back in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified >= after,
                      best.map({ modified > $0.1 }) ?? true else { continue }
                seen += 1
                guard seen <= 200, let meta = Self.codexMetaCwd(file), wanted.contains(meta) || wanted.contains(
                    URL(fileURLWithPath: meta).resolvingSymlinksInPath().path) else { continue }
                best = (file, modified)
            }
        }
        guard let found = best?.0 else { return nil }
        return found.resolvingSymlinksInPath().path.hasPrefix(sessions.resolvingSymlinksInPath().path + "/") ? found.resolvingSymlinksInPath() : nil
    }

    /// The `cwd` of a rollout's `session_meta` (its first line).
    static func codexMetaCwd(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256 << 10)
        guard let newline = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let line = (try? JSONSerialization.jsonObject(with: head[head.startIndex..<newline])) as? [String: Any],
              line["type"] as? String == "session_meta" else { return nil }
        return (line["payload"] as? [String: Any])?["cwd"] as? String
    }
}
