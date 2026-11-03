// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// Claude Code's session log (`~/.claude/projects/<slug>/<session id>.jsonl`): one JSON
/// object per line. `user` lines hold prompts and tool results, `assistant` lines one
/// content block each (text, thinking, tool_use), and the rest is bookkeeping (snapshots,
/// attachments, request shapes) that never reaches the chat. Subagent (`isSidechain`)
/// and meta (`isMeta`) lines are the harness talking to itself.
public struct ClaudeSessionReader: SessionLogReader {
    public let harness = SessionHarness.claude
    /// Read a subagent's own log, whose every line is a sidechain.
    public var sidechain: Bool

    public init(sidechain: Bool = false) {
        self.sidechain = sidechain
    }

    public func title(line: [String: Any]) -> String? {
        switch line["type"] as? String {
        case "custom-title": return nonEmpty(line["customTitle"] as? String)
        case "ai-title": return nonEmpty(line["aiTitle"] as? String)
        case "summary": return nonEmpty(line["summary"] as? String)
        default: return nil
        }
    }

    public func entries(line: [String: Any], offset: Int) -> [SessionEntry] {
        guard sidechain || line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true else { return [] }
        // The summary Claude Code writes after compacting is a `user` line no one typed; the
        // `compact_boundary` before it already reads "Conversation compacted".
        guard !Self.isCompactSummary(line) else { return [] }
        let uuid = line["uuid"] as? String ?? "o\(offset)"
        let timestamp = line["timestamp"] as? String
        switch line["type"] as? String {
        case "user":
            return userEntries(line, uuid: uuid, timestamp: timestamp, offset: offset)
        case "assistant":
            return assistantEntries(line, uuid: uuid, timestamp: timestamp, offset: offset)
        case "system" where line["subtype"] as? String == "compact_boundary":
            return [SessionEntry(id: uuid, kind: .notice, text: "Conversation compacted", timestamp: timestamp, offset: offset)]
        case "system" where line["subtype"] as? String == "local_command":
            guard let notice = Self.notice(line["content"] as? String ?? ""), !notice.isEmpty else { return [] }
            return [SessionEntry(id: uuid, kind: .notice, text: notice, timestamp: timestamp, offset: offset)]
        default:
            return []
        }
    }

    /// The conversation summary written after a compaction (manual, automatic or while idle).
    static func isCompactSummary(_ line: [String: Any]) -> Bool {
        line["type"] as? String == "user" && line["isCompactSummary"] as? Bool == true
    }

    // MARK: User lines

    private func userEntries(_ line: [String: Any], uuid: String, timestamp: String?, offset: Int) -> [SessionEntry] {
        guard let message = line["message"] as? [String: Any] else { return [] }
        var texts: [String] = []
        var images = 0
        var results: [SessionEntry] = []
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            for (index, block) in blocks.enumerated() {
                switch block["type"] as? String {
                case "text": if let text = block["text"] as? String { texts.append(text) }
                case "image": images += 1
                case "tool_result":
                    guard let toolID = block["tool_use_id"] as? String else { continue }
                    let raw = Self.resultText(block["content"])
                    if Self.isHandbackReceipt(raw) { continue }
                    let (output, clipped) = SessionLogLimits.clip(raw, SessionLogLimits.toolOutput)
                    let applied = blocks.count == 1 ? Self.patch(line["toolUseResult"]) : nil
                    let isError = block["is_error"] as? Bool ?? false
                    results.append(SessionEntry(
                        id: "\(uuid):\(index)", kind: .toolResult,
                        result: SessionToolResult(toolID: toolID, output: output, isError: isError,
                                                  diff: applied, truncated: clipped ? true : nil,
                                                  denied: isError && SessionToolResult.isDenial(raw) ? true : nil),
                        timestamp: timestamp, offset: offset))
                    if isError, SessionToolResult.isHarnessBlock(raw) { results[results.count - 1].result?.blocked = true }
                    if blocks.count == 1, let answers = Self.answers(line["toolUseResult"]) {
                        results[results.count - 1].result?.answers = answers
                    }
                default: continue
                }
            }
        }
        guard results.isEmpty else { return results }
        let joined = texts.joined(separator: "\n\n")
        if let notice = Self.notice(joined) {
            return notice.isEmpty ? [] : [SessionEntry(id: uuid, kind: .notice, text: notice, timestamp: timestamp, offset: offset)]
        }
        let (text, _) = SessionLogLimits.clip(joined.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty || images > 0 else { return [] }
        return [SessionEntry(id: uuid, kind: .user, text: text, images: images > 0 ? images : nil, timestamp: timestamp, offset: offset)]
    }

    /// What a harness-written user line stands for: nil for a real prompt, "" to drop it,
    /// otherwise the notice. Claude Code records slash commands and their output as
    /// tagged user text, and an interrupt as a bracketed line.
    static func notice(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted by user") { return "Interrupted" }
        if trimmed.hasPrefix("<local-command-caveat>") || trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<local-command-stderr>") || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") || trimmed.hasPrefix("<task-notification>") {
            return ""
        }
        if trimmed.hasPrefix("<bash-input>") { return "$ " + tag("bash-input", in: trimmed) }
        if trimmed.contains("<command-name>") {
            let name = tag("command-name", in: trimmed)
            let args = tag("command-args", in: trimmed)
            return name.isEmpty ? "" : ([name, args].filter { !$0.isEmpty }.joined(separator: " "))
        }
        if trimmed.hasPrefix("Caveat: The messages below were generated by the user while running local commands") { return "" }
        return nil
    }

    private static func tag(_ name: String, in text: String) -> String {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return "" }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SubagentHandback's acknowledgement, which follows the report in a subagent's log.
    static func isHandbackReceipt(_ output: String) -> Bool {
        output.hasPrefix(#"{"success":true,"message":"Report delivered"#)
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    /// The applied edit as diff lines: Edit and MultiEdit record `structuredPatch` hunks,
    /// Write a new file's `content`.
    static func patch(_ result: Any?) -> [String]? {
        guard let result = result as? [String: Any] else { return nil }
        if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            var lines: [String] = []
            for hunk in hunks {
                if let start = hunk["oldStart"] as? Int, let newStart = hunk["newStart"] as? Int {
                    lines.append("@@ -\(start),\(hunk["oldLines"] as? Int ?? 0) +\(newStart),\(hunk["newLines"] as? Int ?? 0) @@")
                }
                lines += hunk["lines"] as? [String] ?? []
            }
            return SessionLogLimits.clipLines(lines)
        }
        if result["type"] as? String == "create", let content = result["content"] as? String {
            return SessionLogLimits.clipLines(Self.lines(content).map { "+" + $0 })
        }
        return nil
    }

    /// AskUserQuestion's recorded answers, in the order it asked: `toolUseResult.answers`
    /// maps each question's text to the chosen labels (several joined by ", ").
    static func answers(_ result: Any?) -> [SessionAnswer]? {
        guard let result = result as? [String: Any], let answers = result["answers"] as? [String: Any], !answers.isEmpty else { return nil }
        func text(_ value: Any) -> String {
            if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: ", ") }
            return "\(value)"
        }
        let asked = (result["questions"] as? [[String: Any]])?.compactMap { $0["question"] as? String } ?? []
        var ordered = asked.compactMap { question in answers[question].map { SessionAnswer(question: question, answer: text($0)) } }
        for (question, value) in answers.sorted(by: { $0.key < $1.key }) where !asked.contains(question) {
            ordered.append(SessionAnswer(question: question, answer: text(value)))
        }
        return ordered.isEmpty ? nil : ordered
    }

    // MARK: Assistant lines

    private func assistantEntries(_ line: [String: Any], uuid: String, timestamp: String?, offset: Int) -> [SessionEntry] {
        guard let message = line["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return [] }
        // Claude Code's own stand-ins ("No response requested.", API errors) are not the model.
        let synthetic = message["model"] as? String == "<synthetic>"
        var entries: [SessionEntry] = []
        for (index, block) in blocks.enumerated() {
            let id = "\(uuid):\(index)"
            switch block["type"] as? String {
            case "text":
                let (text, _) = SessionLogLimits.clip((block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty, !(synthetic && text == "No response requested.") else { continue }
                entries.append(SessionEntry(id: id, kind: synthetic ? .notice : .assistant, text: text, timestamp: timestamp, offset: offset))
            case "thinking":
                let (text, _) = SessionLogLimits.clip((block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty else { continue }
                entries.append(SessionEntry(id: id, kind: .thinking, text: text, timestamp: timestamp, offset: offset))
            case "tool_use" where block["name"] as? String == "SubagentHandback":
                // A subagent's report to its parent: what it says, not a step.
                let input = block["input"] as? [String: Any] ?? [:]
                let (text, _) = SessionLogLimits.clip((input["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty else { continue }
                entries.append(SessionEntry(id: id, kind: .assistant, text: text, timestamp: timestamp, offset: offset))
            case "tool_use":
                guard let tool = Self.tool(block) else { continue }
                entries.append(SessionEntry(id: id, kind: .tool, tool: tool, timestamp: timestamp, offset: offset))
            default:
                continue
            }
        }
        return entries
    }

    static func tool(_ block: [String: Any]) -> SessionTool? {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { nonEmpty(input[key] as? String) }
        let path = string("file_path") ?? string("notebook_path")
        var tool = SessionTool(id: id, name: name, kind: .of(name), argument: "", path: path)
        switch name {
        case "Bash", "PowerShell":
            tool.argument = oneLine(string("command") ?? "")
        case "Read", "Write", "NotebookEdit", "NotebookRead":
            tool.argument = path ?? ""
            if name == "Write", let content = input["content"] as? String {
                tool.diff = SessionLogLimits.clipLines(lines(content).map { "+" + $0 })
            }
        case "Edit":
            tool.argument = path ?? ""
            tool.edits = [SessionEdit(old: clipEdit(string("old_string") ?? ""), new: clipEdit(string("new_string") ?? ""))]
        case "MultiEdit":
            tool.argument = path ?? ""
            tool.edits = (input["edits"] as? [[String: Any]] ?? []).prefix(40).map {
                SessionEdit(old: clipEdit($0["old_string"] as? String ?? ""), new: clipEdit($0["new_string"] as? String ?? ""))
            }
        case "Grep", "Glob":
            tool.argument = [string("pattern"), string("path")].compactMap { $0 }.joined(separator: " in ")
        case "WebFetch":
            tool.argument = string("url") ?? ""
        case "WebSearch":
            tool.argument = string("query") ?? ""
        case "Task", "Agent":
            tool.argument = string("description") ?? string("prompt").map { oneLine($0) } ?? ""
        case "TodoWrite":
            tool.argument = "\((input["todos"] as? [Any])?.count ?? 0) todos"
        case "AskUserQuestion":
            let asked = (input["questions"] as? [[String: Any]] ?? []).prefix(8)
            tool.argument = oneLine(asked.first?["question"] as? String ?? "")
            let questions = asked.compactMap { item -> SessionQuestion? in
                guard let text = nonEmpty(item["question"] as? String) else { return nil }
                let options = (item["options"] as? [[String: Any]] ?? []).prefix(12).compactMap { nonEmpty($0["label"] as? String) }
                return SessionQuestion(
                    header: nonEmpty(item["header"] as? String), question: SessionLogLimits.clip(text, 1000).0,
                    options: options.map { oneLine($0, limit: 200) }, multiSelect: item["multiSelect"] as? Bool ?? false)
            }
            tool.questions = questions.isEmpty ? nil : questions
        default:
            tool.argument = oneLine(input.values.lazy.compactMap { $0 as? String }.first ?? compactJSON(input))
        }
        return tool
    }

    // MARK: Helpers

    static func oneLine(_ text: String, limit: Int = 300) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func clipEdit(_ text: String) -> String {
        let all = lines(text)
        guard all.count > SessionLogLimits.diffLines else { return SessionLogLimits.clip(text, SessionLogLimits.text).0 }
        return all.prefix(SessionLogLimits.diffLines).joined(separator: "\n")
    }

    static func compactJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

func nonEmpty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}
