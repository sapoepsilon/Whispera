// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// A subagent an agent started: Claude Code's Agent (Task) tool, or a Codex `spawn_agent`
/// child thread. Read from the parent's log (the call, its result, the completion
/// notification) and from the subagent's own log (its steps and tokens so far).
///
/// Claude Code writes a subagent's conversation to
/// `<project>/<session id>/subagents/agent-<agent id>.jsonl`, with a sibling
/// `agent-<agent id>.meta.json` naming the parent call (`toolUseId`), the type and the
/// description. Codex writes a child thread as its own rollout whose `session_meta`
/// names the parent (`parent_thread_id`), and the parent records `SubAgentActivity` items.
public struct SessionSubagent: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case running, done, failed, interrupted
    }

    /// Claude Code's agent id (`a7aa8867f86ea64a8`) or the Codex child thread id.
    public var id: String
    /// The parent's call that started it (`SessionTool.id`), where its card belongs.
    public var toolID: String?
    /// `general-purpose`, `Explore`, …; for Codex the task path's last part.
    public var type: String?
    /// Codex's nickname for the child ("Descartes").
    public var name: String?
    /// The call's short description ("Find herdr iOS control status").
    public var description: String?
    /// The start of the prompt it was given.
    public var prompt: String?
    public var model: String?
    /// Started in the background (Claude Code's async agents).
    public var background: Bool?
    public var status: Status
    /// ISO 8601, as the logs wrote them.
    public var startedAt: String?
    public var endedAt: String?
    /// Run time: the harness's own figure once ended, else up to the read.
    public var elapsedMs: Int?
    /// The subagent's context in tokens (what Claude Code reports as its tokens).
    public var tokens: Int?
    public var toolUses: Int?
    /// Its newest step: "Bash git status", "Read Foo.swift", or the start of what it said.
    public var lastAction: String?
    public var lastActionKind: SessionTool.Kind?
    /// What it reported back, without the harness's trailers.
    public var result: String?
    public var resultTruncated: Bool?
    /// When its own log was last written.
    public var updatedAt: String?
    /// The subagent's own log can be read (`/subagents/{id}/transcript`).
    public var hasTranscript: Bool

    public init(id: String, toolID: String? = nil, type: String? = nil, name: String? = nil, description: String? = nil,
                status: Status = .running) {
        self.id = id
        self.toolID = toolID
        self.type = type
        self.name = name
        self.description = description
        self.status = status
        self.hasTranscript = false
    }

    enum CodingKeys: String, CodingKey {
        case id, toolID = "tool_id", type, name, description, prompt, model, background, status
        case startedAt = "started_at", endedAt = "ended_at", elapsedMs = "elapsed_ms", tokens, toolUses = "tool_uses"
        case lastAction = "last_action", lastActionKind = "last_action_kind", result, resultTruncated = "result_truncated"
        case updatedAt = "updated_at", hasTranscript = "has_transcript"
    }
}

/// Follows the subagents of one session log. Reads forward from where it stopped, so a
/// caller keeps one per log and calls `refresh` whenever it wants the current state; only
/// lines that can concern a subagent are parsed.
///
/// A subagent's own log is served only through `log(of:)`, which knows only the subagents
/// this log started: a client names a subagent by id, never by path.
public struct SessionSubagentTracker: Sendable {
    public let log: URL
    public let harness: SessionHarness
    /// Claude Code's folder of subagent logs (`<session>/subagents`).
    public let folder: URL?
    private let locator: SessionLocator

    private var offset = 0
    private var calls: [String: Call] = [:]
    private var order: [String] = []
    private var children: [String: Child] = [:]
    private var codexParent: String?
    /// The log is itself a subagent's: every line of it is a sidechain.
    private var sidechain = false

    /// The parent's call and what the parent's log says about how it went.
    struct Call: Sendable {
        var toolID: String
        var type: String?
        var description: String?
        var prompt: String?
        var model: String?
        var background = false
        var startedAt: String?
        var agentID: String?
        var status: SessionSubagent.Status?
        var endedAt: String?
        var durationMs: Int?
        var tokens: Int?
        var toolUses: Int?
        var result: String?
        var truncated = false
    }

    /// What a subagent's own log says, read forward like the parent's.
    struct Child: Sendable {
        var path: URL
        var offset = 0
        var size = 0
        var startedAt: String?
        var updatedAt: String?
        var tokens: Int?
        var toolUses = 0
        var lastAction: String?
        var lastKind: SessionTool.Kind?
        var finished = false
        var aborted = false
        var result: String?
        var type: String?
        var description: String?
        var name: String?
        var model: String?
        var toolID: String?
    }

    public init(log: URL, harness: SessionHarness, locator: SessionLocator = SessionLocator()) {
        self.log = log
        self.harness = harness
        self.locator = locator
        folder = harness == .claude ? log.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true) : nil
        if harness == .codex { codexParent = SessionLocator.sessionID(of: log, harness: .codex) }
    }

    /// A subagent's own log as a parent: its subagents live in the same folder.
    public init(subagentLog: URL, folder: URL, locator: SessionLocator = SessionLocator()) {
        log = subagentLog
        harness = .claude
        self.locator = locator
        self.folder = folder
        sidechain = true
    }

    /// The subagents started in this log, oldest first. `ended`: the parent agent is gone,
    /// so whatever still reads as running was cut off with it.
    public mutating func refresh(now: Date = Date(), ended: Bool = false) -> [SessionSubagent] {
        // omp's `task` subagents are not followed yet: its calls show as task steps.
        guard harness != .omp else { return [] }
        scanParent()
        switch harness {
        case .claude: scanClaudeChildren()
        case .codex: scanCodexChildren()
        case .omp: break
        }
        return order.compactMap { subagent(for: $0, now: now, ended: ended) }
    }

    /// The own log of a subagent this log started, by its id; nil for any other id.
    public func log(of id: String) -> URL? {
        guard SessionSubagentTracker.isValidID(id) else { return nil }
        if let child = children[id] { return child.path }
        return nil
    }

    /// Agent ids and Codex thread ids: letters, digits and dashes, 1–64 of them.
    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    // MARK: Parent log

    private static let claudeNeedles = [#""name":"Agent""#, #""name":"Task""#, "task-notification>", #""agents_killed""#,
                                        #""agentId""#, "tool_use_id"].map { Array($0.utf8) }
    private static let codexNeedles = ["SubAgentActivity", #""spawn_agent""#].map { Array($0.utf8) }

    private mutating func scanParent() {
        let needles = harness == .claude ? Self.claudeNeedles : Self.codexNeedles
        var start = offset
        let result = JSONLines.scan(log, from: &start, filter: { line in
            needles.contains { JSONLines.contains(line, $0) }
        }) { line in
            switch harness {
            case .claude: claudeParentLine(line)
            case .codex: codexParentLine(line)
            case .omp: break
            }
        }
        if result == .reset {
            calls = [:]
            order = []
            children = [:]
            offset = 0
            var again = 0
            _ = JSONLines.scan(log, from: &again, filter: { line in needles.contains { JSONLines.contains(line, $0) } }) { line in
                switch harness {
                case .claude: claudeParentLine(line)
                case .codex: codexParentLine(line)
                case .omp: break
                }
            }
            offset = again
        } else {
            offset = start
        }
    }

    private mutating func claudeParentLine(_ line: [String: Any]) {
        guard sidechain || line["isSidechain"] as? Bool != true else { return }
        let timestamp = line["timestamp"] as? String
        switch line["type"] as? String {
        case "assistant":
            let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, name == "Agent" || name == "Task", let id = block["id"] as? String,
                      calls[id] == nil else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                var call = Call(toolID: id)
                call.type = nonEmpty(input["subagent_type"] as? String) ?? "general-purpose"
                call.description = nonEmpty(input["description"] as? String)
                call.prompt = (input["prompt"] as? String).map { SessionLogLimits.clip($0, 2048).0 }
                call.model = nonEmpty(input["model"] as? String)
                call.background = input["run_in_background"] as? Bool ?? false
                call.startedAt = timestamp
                calls[id] = call
                order.append(id)
            }
        case "user":
            guard let message = line["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String, text.contains("<task-notification>") {
                notification(text, timestamp: timestamp)
                return
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text", let text = block["text"] as? String, text.contains("<task-notification>") {
                    notification(text, timestamp: timestamp)
                    continue
                }
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                      var call = calls[id] else { continue }
                let raw = ClaudeSessionReader.resultText(block["content"])
                let info = line["toolUseResult"] as? [String: Any]
                if let agent = info?["agentId"] as? String, Self.isValidID(agent) { call.agentID = agent }
                let isError = block["is_error"] as? Bool ?? false
                if info?["status"] as? String == "async_launched" || info?["isAsync"] as? Bool == true {
                    call.background = true
                } else if isError || raw.hasPrefix("[Request interrupted") {
                    let interrupted = raw.hasPrefix("[Request interrupted") || SessionToolResult.isDenial(raw)
                    call.status = interrupted ? .interrupted : .failed
                    call.endedAt = timestamp
                    call.result = Self.summary(raw).0
                } else {
                    call.status = Self.status(info?["status"] as? String) ?? .done
                    call.endedAt = timestamp
                    call.durationMs = info?["totalDurationMs"] as? Int
                    call.tokens = info?["totalTokens"] as? Int
                    call.toolUses = info?["totalToolUseCount"] as? Int
                    let report = info.map { ClaudeSessionReader.resultText($0["content"]) } ?? ""
                    (call.result, call.truncated) = Self.summary(report.isEmpty ? raw : report)
                    if call.type == nil { call.type = nonEmpty(info?["agentType"] as? String) }
                }
                calls[id] = call
            }
        case "queue-operation":
            if let text = line["content"] as? String, text.contains("<task-notification>") { notification(text, timestamp: timestamp) }
        case "attachment":
            if let attachment = line["attachment"] as? [String: Any], let text = attachment["prompt"] as? String,
               text.contains("<task-notification>") { notification(text, timestamp: timestamp) }
        case "system" where line["subtype"] as? String == "agents_killed":
            for id in order where calls[id]?.background == true && calls[id]?.status == nil {
                calls[id]?.status = .interrupted
                calls[id]?.endedAt = timestamp
            }
        default:
            return
        }
    }

    /// `<task-notification>`: a background agent stopped (Claude Code may say so more than
    /// once for one agent, if it is resumed; the newest wins).
    private mutating func notification(_ text: String, timestamp: String?) {
        guard let toolID = Self.tag("tool-use-id", in: text), var call = calls[toolID] else { return }
        if let agent = Self.tag("task-id", in: text), Self.isValidID(agent) { call.agentID = agent }
        let status = Self.tag("status", in: text)
        call.status = Self.status(status) ?? .done
        call.endedAt = timestamp
        if let result = Self.tag("result", in: text) { (call.result, call.truncated) = Self.summary(result) }
        if let usage = Self.tag("usage", in: text) {
            for row in usage.split(separator: "\n") {
                let parts = row.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let value = Int(parts[1]) else { continue }
                switch parts[0] {
                case "total_tokens", "subagent_tokens": call.tokens = value
                case "tool_uses": call.toolUses = value
                case "duration_ms": call.durationMs = value
                default: continue
                }
            }
        }
        calls[toolID] = call
    }

    private mutating func codexParentLine(_ line: [String: Any]) {
        let payload = line["payload"] as? [String: Any] ?? [:]
        let timestamp = line["timestamp"] as? String
        if line["type"] as? String == "event_msg", payload["type"] as? String == "item_completed",
           let item = payload["item"] as? [String: Any], item["type"] as? String == "SubAgentActivity" {
            guard let thread = item["agent_thread_id"] as? String, Self.isValidID(thread) else { return }
            let toolID = item["id"] as? String ?? thread
            var call = calls[toolID] ?? Call(toolID: toolID)
            if calls[toolID] == nil {
                call.startedAt = timestamp
                order.append(toolID)
            }
            call.agentID = thread
            call.model = nonEmpty(item["model"] as? String) ?? call.model
            if let path = item["agent_path"] as? String {
                call.type = path.split(separator: "/").last.map(String.init)
                call.description = call.description ?? path
            }
            if let status = Self.status(item["kind"] as? String) {
                call.status = status
                call.endedAt = timestamp
            }
            calls[toolID] = call
        }
    }

    // MARK: Subagent logs

    private mutating func scanClaudeChildren() {
        guard let folder else { return }
        var byTool: [String: String] = [:]
        for id in order { if let agent = calls[id]?.agentID { byTool[id] = agent } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let known = Set(children.keys)
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
            let agent = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard Self.isValidID(agent) else { continue }
            if known.contains(agent), children[agent]?.toolID != nil, children[agent]?.finished == true { continue }
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let toolID = meta["toolUseId"] as? String, calls[toolID] != nil else { continue }
            if calls[toolID]?.agentID == nil { calls[toolID]?.agentID = agent }
            let file = folder.appendingPathComponent("agent-\(agent).jsonl")
            guard let path = contained(file) else { continue }
            var child = children[agent] ?? Child(path: path)
            child.toolID = toolID
            child.type = nonEmpty(meta["agentType"] as? String)
            child.description = nonEmpty(meta["description"] as? String)
            child.model = nonEmpty(meta["model"] as? String)
            child.finished = meta["finished"] as? Bool ?? false
            children[agent] = child
        }
        for agent in children.keys { readClaudeChild(agent) }
    }

    private mutating func readClaudeChild(_ agent: String) {
        guard var child = children[agent] else { return }
        let size = JSONLines.size(child.path)
        guard size != child.size else { return }
        if size < child.size { child = Child(path: child.path, toolID: child.toolID) }
        var start = child.offset
        _ = JSONLines.scan(child.path, from: &start, filter: { _ in true }) { line in
            let timestamp = line["timestamp"] as? String
            if child.startedAt == nil { child.startedAt = timestamp }
            if let timestamp { child.updatedAt = timestamp }
            guard line["type"] as? String == "assistant", let message = line["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                if total > 0 { child.tokens = total }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_use" where block["name"] as? String == "SubagentHandback":
                    child.toolUses += 1
                    if let text = nonEmpty((block["input"] as? [String: Any])?["message"] as? String) {
                        child.lastAction = ClaudeSessionReader.oneLine(text, limit: 160)
                        child.lastKind = nil
                        child.result = text
                    }
                case "tool_use":
                    guard let tool = ClaudeSessionReader.tool(block) else { continue }
                    child.toolUses += 1
                    child.lastAction = Self.action(tool)
                    child.lastKind = tool.kind
                case "text":
                    if let text = nonEmpty(block["text"] as? String) {
                        child.lastAction = ClaudeSessionReader.oneLine(text, limit: 160)
                        child.lastKind = nil
                    }
                default:
                    continue
                }
            }
        }
        child.offset = start
        child.size = size
        children[agent] = child
    }

    private mutating func scanCodexChildren() {
        for id in order {
            guard let thread = calls[id]?.agentID else { continue }
            if children[thread] == nil {
                guard let file = locator.codexLog(sessionID: thread, maxDays: 3),
                      let meta = SessionLocator.codexMeta(file),
                      meta["parent_thread_id"] as? String == codexParent || Self.parentOf(meta) == codexParent
                else { continue }
                var child = Child(path: file, toolID: id)
                child.name = nonEmpty(meta["agent_nickname"] as? String)
                if let path = meta["agent_path"] as? String { child.type = path.split(separator: "/").last.map(String.init) }
                children[thread] = child
            }
            readCodexChild(thread)
        }
    }

    private static func parentOf(_ meta: [String: Any]) -> String? {
        (((meta["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
    }

    private mutating func readCodexChild(_ thread: String) {
        guard var child = children[thread] else { return }
        let size = JSONLines.size(child.path)
        guard size != child.size else { return }
        var start = child.offset
        _ = JSONLines.scan(child.path, from: &start, filter: { _ in true }) { line in
            let timestamp = line["timestamp"] as? String
            if child.startedAt == nil { child.startedAt = timestamp }
            if let timestamp { child.updatedAt = timestamp }
            let payload = line["payload"] as? [String: Any] ?? [:]
            switch (line["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "token_count"?):
                let info = payload["info"] as? [String: Any]
                if let total = (info?["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int { child.tokens = total }
            case ("event_msg", "task_complete"?), ("event_msg", "turn_complete"?):
                child.finished = true
                child.aborted = false
                if let message = nonEmpty(payload["last_agent_message"] as? String) { child.result = message }
            case ("event_msg", "turn_aborted"?):
                child.aborted = true
            case ("event_msg", "task_started"?), ("event_msg", "turn_started"?):
                child.finished = false
                child.aborted = false
            case ("response_item", "function_call"?), ("response_item", "custom_tool_call"?), ("response_item", "local_shell_call"?):
                let name = payload["name"] as? String ?? "exec"
                let argument = ClaudeSessionReader.oneLine(payload["arguments"] as? String ?? payload["input"] as? String ?? "", limit: 160)
                child.toolUses += 1
                child.lastAction = argument.isEmpty ? name : "\(name) \(argument)"
                child.lastKind = .of(name)
            case ("event_msg", "item_completed"?):
                let item = payload["item"] as? [String: Any] ?? [:]
                if item["type"] as? String == "AgentMessage" {
                    let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    if let text = nonEmpty(text) {
                        child.lastAction = ClaudeSessionReader.oneLine(text, limit: 160)
                        child.lastKind = nil
                        child.result = text
                    }
                }
            default:
                return
            }
        }
        child.offset = start
        child.size = size
        children[thread] = child
    }

    // MARK: Assembly

    private func subagent(for toolID: String, now: Date, ended: Bool) -> SessionSubagent? {
        guard let call = calls[toolID] else { return nil }
        let child = call.agentID.flatMap { children[$0] }
        var agent = SessionSubagent(id: call.agentID ?? toolID, toolID: toolID, type: call.type ?? child?.type,
                                    name: child?.name, description: call.description ?? child?.description)
        agent.prompt = call.prompt
        agent.model = call.model ?? child?.model
        agent.background = call.background ? true : nil
        agent.startedAt = call.startedAt ?? child?.startedAt
        agent.updatedAt = child?.updatedAt
        agent.tokens = call.tokens ?? child?.tokens
        agent.toolUses = call.toolUses ?? child.map(\.toolUses)
        agent.lastAction = child?.lastAction
        agent.lastActionKind = child?.lastKind
        agent.hasTranscript = child != nil
        var status = call.status
        if status == nil, let child, harness == .codex {
            if child.finished { status = .done } else if child.aborted { status = .interrupted }
        }
        if status == nil, ended { status = child?.finished == true ? .done : .interrupted }
        agent.status = status ?? .running
        agent.endedAt = call.endedAt ?? (agent.status == .running ? nil : child?.updatedAt)
        var result = call.result ?? (agent.status == .running ? nil : child?.result)
        // A background agent's notification only points at its handback; the report is in its log.
        if let text = result, Self.isHandbackPointer(text), let report = child?.result { result = report }
        if let result {
            let (text, cut) = Self.summary(result)
            agent.result = text
            agent.resultTruncated = cut || call.truncated ? true : nil
        }
        let start = agent.startedAt.flatMap(Self.date)
        if let duration = call.durationMs {
            agent.elapsedMs = duration
        } else if let start {
            let end = agent.status == .running ? now : (agent.endedAt.flatMap(Self.date) ?? now)
            agent.elapsedMs = max(0, Int(end.timeIntervalSince(start) * 1000))
        }
        return agent
    }

    // MARK: Helpers

    static func status(_ text: String?) -> SessionSubagent.Status? {
        switch text?.lowercased() {
        case "completed"?, "complete"?, "done"?, "success"?: return .done
        case "failed"?, "error"?, "errored"?: return .failed
        case "killed"?, "stopped"?, "cancelled"?, "canceled"?, "interrupted"?, "aborted"?: return .interrupted
        default: return nil
        }
    }

    /// A subagent's report without Claude Code's trailers (`agentId: …`, `<usage>…`).
    static func summary(_ raw: String) -> (String, Bool) {
        var text = raw
        // Claude Code frames a report for the parent model and indents it by two spaces.
        if let frame = text.range(of: "The report follows:\n") {
            text = text[frame.upperBound...].components(separatedBy: "\n")
                .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
        }
        if let open = text.range(of: "<tools-used-before-summary>"),
           let close = text.range(of: "</tools-used-before-summary>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let usage = text.range(of: "\n<usage>") { text = String(text[..<usage.lowerBound]) }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("agentId: ") {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionLogLimits.clip(text, SessionLogLimits.toolOutput)
    }

    static func isHandbackPointer(_ text: String) -> Bool {
        text.contains("report was delivered to you as a message from") && text.contains("SubagentHandback")
    }

    static func action(_ tool: SessionTool) -> String {
        let argument = tool.argument.count > 160 ? String(tool.argument.prefix(160)) + "…" : tool.argument
        return argument.isEmpty ? tool.name : "\(tool.name) \(argument)"
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>") else { return nil }
        let close = text.range(of: "</\(name)>", options: .backwards, range: open.upperBound..<text.endIndex)
        return text[open.upperBound..<(close?.lowerBound ?? text.endIndex)].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The file, if it is a regular file whose real path is inside the subagent folder.
    private func contained(_ file: URL) -> URL? {
        guard let folder else { return nil }
        let real = file.resolvingSymlinksInPath()
        guard real.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              (try? real.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return real
    }
}

/// Complete JSONL lines read forward from an offset, skipping the ones a filter turns down
/// without parsing them.
enum JSONLines {
    enum Outcome: Equatable { case read, reset }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Reads from `offset` to the last complete line and moves `offset` past it. A file
    /// smaller than `offset` was replaced: `.reset`, and nothing is read. A first read of a
    /// file longer than `maxBytes` starts that far from its end.
    @discardableResult
    static func scan(_ url: URL, from offset: inout Int, maxBytes: Int = 64 << 20,
                     filter: (UnsafeRawBufferPointer) -> Bool, body: ([String: Any]) -> Void) -> Outcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .read }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard offset <= size else { return .reset }
        var position = offset
        var skipFirst = false
        if position == 0, size > maxBytes {
            position = size - maxBytes
            skipFirst = true
        }
        guard (try? handle.seek(toOffset: UInt64(position))) != nil else { return .read }
        var pending = Data()
        var end = offset
        while position < size {
            let data = handle.readData(ofLength: min(1 << 20, size - position))
            guard !data.isEmpty else { break }
            let base = position - pending.count
            position += data.count
            pending.append(data)
            var cursor = pending.startIndex
            while let newline = pending[cursor...].firstIndex(of: 0x0A) {
                let line = pending[cursor..<newline]
                if skipFirst {
                    skipFirst = false
                } else if !line.isEmpty, line.count <= SessionLogLimits.line {
                    let wanted = line.withUnsafeBytes { filter($0) }
                    if wanted, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { body(object) }
                }
                cursor = newline + 1
                end = base + (cursor - pending.startIndex)
            }
            pending = Data(pending[cursor...])
            if pending.count > SessionLogLimits.line { pending.removeAll(); skipFirst = true }
        }
        offset = end
        return .read
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress, needle.count) != nil }
    }
}

extension SessionLocator {
    /// The `session_meta` payload of a Codex rollout (its first line).
    static func codexMeta(_ file: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256 << 10)
        guard let newline = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let line = (try? JSONSerialization.jsonObject(with: head[head.startIndex..<newline])) as? [String: Any],
              line["type"] as? String == "session_meta" else { return nil }
        return line["payload"] as? [String: Any]
    }
}

extension SessionLog {
    /// A subagent's own log, read like a session's: Claude Code marks every line of it as
    /// a sidechain, which the session reader otherwise skips.
    public static func readSubagent(_ url: URL, harness: SessionHarness, since: Int? = nil, before: Int? = nil,
                                    limit: Int = 300) throws -> SessionPage {
        try read(url, harness: harness, since: since, before: before, limit: limit, sidechain: true)
    }
}

/// The subagent lines Claude Code draws under its prompt while they run, for an agent whose
/// log can't be read: `◯ general-purpose  Simplifying the regex…   18m 52s · ↓ 306.0k tokens`.
/// A line wrapped by a narrow pane is joined back to its marker line first.
public enum SubagentScreenLines {
    static let markers: Set<Character> = ["◯", "○", "◉", "●", "⏺", "✻", "✶", "✳", "✢", "·", "*", "⎿"]

    public static func parse(_ screen: String) -> [SessionSubagent] {
        var joined: [String] = []
        var current: String?
        for raw in screen.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let first = line.first, first == "◯" || first == "○" || first == "◉" {
                if let current { joined.append(current) }
                current = line
            } else if var open = current {
                // Wrapped tail of the marker line, until its stats are complete.
                if line.isEmpty || stats(open) != nil { joined.append(open); current = nil; continue }
                open += " " + line
                current = open
            }
        }
        if let current { joined.append(current) }
        var result: [SessionSubagent] = []
        for line in joined {
            guard let (body, elapsed, tokens) = stats(line) else { continue }
            var text = body.drop { markers.contains($0) || $0 == " " }
            let type = text.prefix { !$0.isWhitespace }
            guard !type.isEmpty else { continue }
            text = text.dropFirst(type.count)
            let description = text.trimmingCharacters(in: .whitespaces)
            var agent = SessionSubagent(id: "screen-\(result.count)", type: String(type),
                                        description: description.isEmpty ? nil : description, status: .running)
            agent.elapsedMs = elapsed
            agent.tokens = tokens
            result.append(agent)
        }
        return result
    }

    /// Splits `… 18m 52s · ↓ 306.0k tokens` off the end of a line.
    static func stats(_ line: String) -> (String, Int?, Int?)? {
        let pattern = #"^(.*?)\s+((?:\d+h\s*)?(?:\d+m\s*)?\d+s)(?:\s*·\s*[↓↑]?\s*([\d.]+)([kKmM]?)\s*tokens)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let bodyRange = Range(match.range(at: 1), in: line), let timeRange = Range(match.range(at: 2), in: line)
        else { return nil }
        var seconds = 0
        var number = 0
        for character in line[timeRange] {
            if let digit = character.wholeNumberValue { number = number * 10 + digit; continue }
            switch character {
            case "h": seconds += number * 3600; number = 0
            case "m": seconds += number * 60; number = 0
            case "s": seconds += number; number = 0
            default: continue
            }
        }
        var tokens: Int?
        if let valueRange = Range(match.range(at: 3), in: line), let value = Double(line[valueRange]) {
            let unit = Range(match.range(at: 4), in: line).map { line[$0].lowercased() } ?? ""
            tokens = Int(value * (unit == "k" ? 1_000 : unit == "m" ? 1_000_000 : 1))
        }
        return (String(line[bodyRange]), seconds * 1000, tokens)
    }
}
