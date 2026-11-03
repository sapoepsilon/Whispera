// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// Codex's rollout log (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<session id>.jsonl`).
/// The conversation is read from its `event_msg` lines only: `response_item` lines are the
/// model's raw context (developer instructions, AGENTS.md, environment) and would repeat
/// every message.
///
/// Current Codex writes one `item_completed` event per finished item (UserMessage,
/// AgentMessage, Reasoning, CommandExecution, FileChange, …). Older Codex wrote
/// `user_message`, `agent_message`, `exec_command_end` and `patch_apply_end`; those are
/// read only from a log without item events (`legacyEvents`), so a log that has both
/// never shows a message twice.
public struct CodexSessionReader: SessionLogReader {
    public let harness = SessionHarness.codex
    public var legacyEvents: Bool

    public init(legacyEvents: Bool = false) {
        self.legacyEvents = legacyEvents
    }

    public func title(line: [String: Any]) -> String? {
        let payload = line["payload"] as? [String: Any] ?? [:]
        guard line["type"] as? String == "event_msg", payload["type"] as? String == "thread_name_updated" else { return nil }
        return nonEmpty(payload["thread_name"] as? String)
    }

    public func entries(line: [String: Any], offset: Int) -> [SessionEntry] {
        guard line["type"] as? String == "event_msg", let payload = line["payload"] as? [String: Any] else { return [] }
        let timestamp = line["timestamp"] as? String
        switch payload["type"] as? String {
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return [] }
            return itemEntries(item, timestamp: timestamp, offset: offset)
        case "turn_aborted":
            return [SessionEntry(id: "o\(offset)", kind: .notice, text: "Interrupted", timestamp: timestamp, offset: offset)]
        case "user_message" where legacyEvents:
            let (text, _) = SessionLogLimits.clip((payload["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            let images = (payload["images"] as? [Any])?.count ?? 0
            guard !text.isEmpty || images > 0 else { return [] }
            return [SessionEntry(id: "o\(offset)", kind: .user, text: text, images: images > 0 ? images : nil, timestamp: timestamp, offset: offset)]
        case "agent_message" where legacyEvents:
            let (text, _) = SessionLogLimits.clip((payload["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            return text.isEmpty ? [] : [SessionEntry(id: "o\(offset)", kind: .assistant, text: text, timestamp: timestamp, offset: offset)]
        case "exec_command_end" where legacyEvents:
            let id = payload["call_id"] as? String ?? "o\(offset)"
            let output = payload["aggregated_output"] as? String ?? payload["formatted_output"] as? String ?? payload["stdout"] as? String ?? ""
            return command(id: id, command: payload["command"], parsed: payload["parsed_cmd"], output: output,
                           failed: (payload["exit_code"] as? Int ?? 0) != 0, timestamp: timestamp, offset: offset)
        case "patch_apply_end" where legacyEvents:
            let id = payload["call_id"] as? String ?? "o\(offset)"
            return patch(id: id, changes: payload["changes"] as? [String: Any] ?? [:], output: payload["stdout"] as? String ?? "",
                         failed: payload["success"] as? Bool == false, timestamp: timestamp, offset: offset)
        default:
            return []
        }
    }

    private func itemEntries(_ item: [String: Any], timestamp: String?, offset: Int) -> [SessionEntry] {
        let id = item["id"] as? String ?? "o\(offset)"
        switch item["type"] as? String {
        case "UserMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            let images = content.filter { ["image", "local_image", "localImage"].contains($0["type"] as? String ?? "") }.count
            let (clipped, _) = SessionLogLimits.clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !clipped.isEmpty || images > 0 else { return [] }
            return [SessionEntry(id: id, kind: .user, text: clipped, images: images > 0 ? images : nil, timestamp: timestamp, offset: offset)]
        case "AgentMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            let (clipped, _) = SessionLogLimits.clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return clipped.isEmpty ? [] : [SessionEntry(id: id, kind: .assistant, text: clipped, timestamp: timestamp, offset: offset)]
        case "Reasoning":
            let text = ((item["summary_text"] as? [String]) ?? []).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [SessionEntry(id: id, kind: .thinking, text: SessionLogLimits.clip(text).0, timestamp: timestamp, offset: offset)]
        case "CommandExecution":
            let status = item["status"] as? String
            let output = item["aggregated_output"] as? String ?? item["formatted_output"] as? String ?? item["stdout"] as? String
                ?? (status == "declined" ? "Declined" : "")
            let failed = (item["exit_code"] as? Int ?? 0) != 0 || status == "declined" || status == "failed"
            return command(id: id, command: item["command"], parsed: item["parsed_cmd"], output: output, failed: failed,
                           timestamp: timestamp, offset: offset)
        case "FileChange":
            let output = [item["stdout"] as? String, item["stderr"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            return patch(id: id, changes: item["changes"] as? [String: Any] ?? [:], output: output,
                         failed: ["failed", "declined"].contains(item["status"] as? String ?? ""), timestamp: timestamp, offset: offset)
        case "McpToolCall":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            let tool = SessionTool(id: id, name: name.isEmpty ? "mcp" : name, kind: .other,
                                   argument: ClaudeSessionReader.oneLine(ClaudeSessionReader.compactJSON(item["arguments"] ?? [:])))
            return [SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset)]
        case "WebSearch":
            let tool = SessionTool(id: id, name: "web_search", kind: .fetch, argument: item["query"] as? String ?? "")
            return [SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset)]
        case "Extension" where item["query"] is String:
            let tool = SessionTool(id: id, name: "web_search", kind: .fetch, argument: item["query"] as? String ?? "")
            return [SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset)]
        case "SubAgentActivity" where item["kind"] as? String == "started":
            // The card for the child thread hangs off this call (`SessionSubagent.toolID`).
            let path = item["agent_path"] as? String ?? ""
            let tool = SessionTool(id: id, name: "spawn_agent", kind: .task, argument: path)
            return [SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset)]
        case "ContextCompaction":
            return [SessionEntry(id: id, kind: .notice, text: "Conversation compacted", timestamp: timestamp, offset: offset)]
        default:
            return []
        }
    }

    /// A shell command and its output as a call and its result. `parsed_cmd` tells a read
    /// (`cat calc.py`) or a search (`rg …`) from anything else.
    private func command(id: String, command: Any?, parsed: Any?, output: String, failed: Bool,
                         timestamp: String?, offset: Int) -> [SessionEntry] {
        var argv = command as? [String] ?? []
        if argv.count >= 3, ["-lc", "-c"].contains(argv[argv.count - 2]) { argv = [argv[argv.count - 1]] }
        let line = (command as? String) ?? argv.joined(separator: " ")
        var tool = SessionTool(id: id, name: "exec", kind: .run, argument: ClaudeSessionReader.oneLine(line))
        if let parsed = (parsed as? [[String: Any]]), parsed.count == 1, let first = parsed.first {
            switch first["type"] as? String {
            case "read":
                tool.kind = .read
                tool.path = first["path"] as? String
                tool.argument = first["path"] as? String ?? first["name"] as? String ?? tool.argument
            case "search", "list_files":
                tool.kind = .search
                tool.argument = [first["query"] as? String, first["path"] as? String].compactMap { $0 }.joined(separator: " in ")
                if tool.argument.isEmpty { tool.argument = ClaudeSessionReader.oneLine(line) }
            default: break
            }
        }
        let (clipped, cut) = SessionLogLimits.clip(output, SessionLogLimits.toolOutput)
        return [
            SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset),
            SessionEntry(id: id + ":result", kind: .toolResult,
                         result: SessionToolResult(toolID: id, output: clipped, isError: failed, truncated: cut ? true : nil),
                         timestamp: timestamp, offset: offset),
        ]
    }

    /// A patch as one edit card per file, each with its unified diff.
    private func patch(id: String, changes: [String: Any], output: String, failed: Bool,
                       timestamp: String?, offset: Int) -> [SessionEntry] {
        var entries: [SessionEntry] = []
        for (index, path) in changes.keys.sorted().enumerated() {
            let change = changes[path] as? [String: Any] ?? [:]
            let toolID = changes.count == 1 ? id : "\(id)#\(index)"
            var kind = change["type"] as? String
            var diff: [String] = []
            if let unified = change["unified_diff"] as? String {
                diff = ClaudeSessionReader.lines(unified)
            } else if let update = change["update"] as? [String: Any], let unified = update["unified_diff"] as? String {
                kind = "update"
                diff = ClaudeSessionReader.lines(unified)
            } else if let add = change["add"] as? [String: Any] {
                kind = "add"
                diff = ClaudeSessionReader.lines(add["content"] as? String ?? "").map { "+" + $0 }
            } else if change["delete"] != nil {
                kind = "delete"
            } else if let content = change["content"] as? String {
                diff = ClaudeSessionReader.lines(content).map { "+" + $0 }
            }
            diff = diff.filter { !$0.hasPrefix("\\ No newline") }
            let tool = SessionTool(id: toolID, name: "apply_patch", kind: kind == "add" ? .write : .edit,
                                   argument: path, path: path, diff: SessionLogLimits.clipLines(diff))
            entries.append(SessionEntry(id: toolID, kind: .tool, tool: tool, timestamp: timestamp, offset: offset))
            let (clipped, cut) = SessionLogLimits.clip(output, SessionLogLimits.toolOutput)
            entries.append(SessionEntry(id: toolID + ":result", kind: .toolResult,
                                        result: SessionToolResult(toolID: toolID, output: clipped, isError: failed, truncated: cut ? true : nil),
                                        timestamp: timestamp, offset: offset))
        }
        return entries
    }
}
