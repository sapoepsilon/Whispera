// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// oh-my-pi's session log (`~/.omp/agent/sessions/<folder of cwd>/<time>_<session id>.jsonl`).
///
/// Every line has a `type`. The conversation is in `message` lines, whose `message.role` is
/// `user`, `assistant` or `toolResult`: an assistant message holds `text`, `thinking` and
/// `toolCall` blocks, and each call's result is its own `toolResult` message naming
/// `toolCallId`. A `compaction` line replaces earlier turns with a summary. The first line is a
/// padded `title` record that omp rewrites in place (same length), and `title_change` lines
/// carry later titles. `custom`, `mode_change`, `model_change` and the like are omp's own
/// bookkeeping and are not shown.
public struct OmpSessionReader: SessionLogReader {
    public let harness = SessionHarness.omp

    public init() {}

    public func title(line: [String: Any]) -> String? {
        switch line["type"] as? String {
        case "title", "title_change": return nonEmpty(line["title"] as? String)
        default: return nil
        }
    }

    public func entries(line: [String: Any], offset: Int) -> [SessionEntry] {
        let timestamp = line["timestamp"] as? String
        let lineID = line["id"] as? String ?? "o\(offset)"
        switch line["type"] as? String {
        case "message":
            guard let message = line["message"] as? [String: Any] else { return [] }
            switch message["role"] as? String {
            case "user": return userEntries(message, id: lineID, timestamp: timestamp, offset: offset)
            case "assistant": return assistantEntries(message, id: lineID, timestamp: timestamp, offset: offset)
            case "toolResult": return resultEntries(message, id: lineID, timestamp: timestamp, offset: offset)
            default: return []
            }
        case "compaction":
            return [SessionEntry(id: lineID, kind: .notice, text: "Conversation compacted", timestamp: timestamp, offset: offset)]
        default:
            return []
        }
    }

    // MARK: Messages

    private func userEntries(_ message: [String: Any], id: String, timestamp: String?, offset: Int) -> [SessionEntry] {
        let blocks = Self.blocks(message["content"])
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
        let images = blocks.filter { $0["type"] as? String == "image" }.count
        let (clipped, _) = SessionLogLimits.clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clipped.isEmpty || images > 0 else { return [] }
        return [SessionEntry(id: id, kind: .user, text: clipped, images: images > 0 ? images : nil, timestamp: timestamp, offset: offset)]
    }

    private func assistantEntries(_ message: [String: Any], id: String, timestamp: String?, offset: Int) -> [SessionEntry] {
        var entries: [SessionEntry] = []
        for (index, block) in Self.blocks(message["content"]).enumerated() {
            let blockID = "\(id):\(index)"
            switch block["type"] as? String {
            case "text":
                let (text, _) = SessionLogLimits.clip((block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty else { continue }
                entries.append(SessionEntry(id: blockID, kind: .assistant, text: text, timestamp: timestamp, offset: offset))
            case "thinking":
                let raw = nonEmpty(block["thinking"] as? String) ?? nonEmpty(block["summary"] as? String) ?? ""
                let (text, _) = SessionLogLimits.clip(raw)
                guard !text.isEmpty else { continue }
                entries.append(SessionEntry(id: blockID, kind: .thinking, text: text, timestamp: timestamp, offset: offset))
            case "toolCall":
                guard let tool = Self.tool(block) else { continue }
                entries.append(SessionEntry(id: blockID, kind: .tool, tool: tool, timestamp: timestamp, offset: offset))
            default:
                continue
            }
        }
        switch message["stopReason"] as? String {
        case "aborted":
            entries.append(SessionEntry(id: id + ":stop", kind: .notice, text: "Interrupted", timestamp: timestamp, offset: offset))
        case "error":
            let detail = nonEmpty(message["errorMessage"] as? String).map { ClaudeSessionReader.oneLine($0, limit: 200) }
            entries.append(SessionEntry(id: id + ":stop", kind: .notice, text: detail.map { "Error: " + $0 } ?? "Error",
                                        timestamp: timestamp, offset: offset))
        default:
            break
        }
        return entries
    }

    private func resultEntries(_ message: [String: Any], id: String, timestamp: String?, offset: Int) -> [SessionEntry] {
        guard let toolID = message["toolCallId"] as? String else { return [] }
        let details = message["details"] as? [String: Any] ?? [:]
        let text = Self.blocks(message["content"]).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        let (clipped, cut) = SessionLogLimits.clip(text, SessionLogLimits.toolOutput)
        let isError = message["isError"] as? Bool == true || details["isError"] as? Bool == true
        var result = SessionToolResult(toolID: toolID, output: clipped, isError: isError, truncated: cut ? true : nil)
        if let diff = details["diff"] as? String { result.diff = Self.diff(diff) }
        if isError, SessionToolResult.isDenial(clipped) { result.denied = true }
        if message["toolName"] as? String == "ask", let answers = Self.answers(details["results"]) { result.answers = answers }
        return [SessionEntry(id: id, kind: .toolResult, result: result, timestamp: timestamp, offset: offset)]
    }

    // MARK: Tools

    /// omp's tools (`bash`, `read`, `edit`, `write`, `glob`, `find`, `web_search`, `task`, `ask`,
    /// `todo`, `eval`, `wait`, `goal`) on the shared kinds.
    static func tool(_ block: [String: Any]) -> SessionTool? {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
        let input = block["arguments"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { nonEmpty(input[key] as? String) }
        let path = string("path")
        var tool = SessionTool(id: id, name: name, kind: kind(name), argument: "", path: path)
        switch name {
        case "bash":
            tool.argument = ClaudeSessionReader.oneLine(string("command") ?? "")
        case "read":
            tool.argument = path ?? ""
        case "write":
            tool.argument = path ?? ""
            if let content = input["content"] as? String {
                tool.diff = SessionLogLimits.clipLines(ClaudeSessionReader.lines(content).map { "+" + $0 })
            }
        case "edit":
            tool.argument = path ?? ""
            tool.edits = [SessionEdit(old: clipEdit(input["old_string"] as? String ?? ""), new: clipEdit(input["new_string"] as? String ?? ""))]
        case "glob":
            tool.argument = [string("pattern"), path].compactMap { $0 }.joined(separator: " in ")
        case "find", "grep", "web_search":
            tool.argument = string("query") ?? string("pattern") ?? ""
        case "task":
            let tasks = input["tasks"] as? [Any]
            tool.argument = string("i") ?? string("task").map { ClaudeSessionReader.oneLine($0) }
                ?? tasks.map { "\($0.count) tasks" } ?? string("agent") ?? ""
        case "eval":
            tool.argument = string("title") ?? string("i") ?? ClaudeSessionReader.oneLine(string("code") ?? "")
        case "ask":
            let asked = (input["questions"] as? [[String: Any]] ?? []).prefix(8)
            tool.argument = ClaudeSessionReader.oneLine(asked.first?["question"] as? String ?? string("i") ?? "")
            let questions = asked.compactMap { item -> SessionQuestion? in
                guard let text = nonEmpty(item["question"] as? String) else { return nil }
                let options = (item["options"] as? [Any] ?? []).prefix(12).compactMap { option -> String? in
                    if let label = option as? String { return nonEmpty(label) }
                    return nonEmpty((option as? [String: Any])?["label"] as? String)
                }
                return SessionQuestion(
                    header: nonEmpty(item["header"] as? String) ?? nonEmpty(item["id"] as? String),
                    question: SessionLogLimits.clip(text, 1000).0, options: options.map { ClaudeSessionReader.oneLine($0, limit: 200) },
                    multiSelect: item["multi"] as? Bool ?? item["multiSelect"] as? Bool ?? false)
            }
            tool.questions = questions.isEmpty ? nil : questions
        default:
            // omp's `i` is the model's own one-line intent for the call ("Reading hello.py").
            tool.argument = string("i") ?? ClaudeSessionReader.oneLine(
                input.values.lazy.compactMap { $0 as? String }.first ?? ClaudeSessionReader.compactJSON(input))
        }
        return tool
    }

    static func kind(_ name: String) -> SessionTool.Kind {
        switch name {
        case "find", "glob", "grep": return .search
        case "eval": return .run
        case "todo", "wait", "goal", "ask": return .other
        default: return .of(name)
        }
    }

    /// omp's edit diff (` 1|kept`, `-2|old`, `+2|new`) as unified diff lines.
    static func diff(_ text: String) -> [String]? {
        let lines = ClaudeSessionReader.lines(text).map { line -> String in
            guard let first = line.first, ["+", "-", " "].contains(first) else { return line }
            let rest = line.dropFirst()
            if let bar = rest.firstIndex(of: "|"), rest[rest.startIndex..<bar].allSatisfy({ $0.isNumber || $0 == " " }) {
                return String(first) + rest[rest.index(after: bar)...]
            }
            return line
        }
        return lines.isEmpty ? nil : SessionLogLimits.clipLines(lines)
    }

    /// The `ask` tool's `details.results`: each question and the options chosen.
    static func answers(_ results: Any?) -> [SessionAnswer]? {
        guard let results = results as? [[String: Any]] else { return nil }
        let answers = results.compactMap { item -> SessionAnswer? in
            guard let question = nonEmpty(item["question"] as? String) else { return nil }
            var chosen = (item["selectedOptions"] as? [String]) ?? []
            if let custom = nonEmpty(item["customInput"] as? String) ?? nonEmpty(item["custom"] as? String) { chosen.append(custom) }
            return SessionAnswer(question: question, answer: chosen.joined(separator: ", "))
        }
        return answers.isEmpty ? nil : answers
    }

    // MARK: Helpers

    static func blocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return [["type": "text", "text": text]] }
        return content as? [[String: Any]] ?? []
    }

    private static func clipEdit(_ text: String) -> String {
        let all = ClaudeSessionReader.lines(text)
        guard all.count > SessionLogLimits.diffLines else { return SessionLogLimits.clip(text, SessionLogLimits.text).0 }
        return all.prefix(SessionLogLimits.diffLines).joined(separator: "\n")
    }
}
