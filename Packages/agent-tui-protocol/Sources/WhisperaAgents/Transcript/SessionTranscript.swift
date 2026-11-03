// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// The agents whose own session log can be read as a conversation.
public enum SessionHarness: String, Codable, Sendable, CaseIterable {
    /// Claude Code: `~/.claude/projects/<slug of cwd>/<session id>.jsonl`.
    case claude
    /// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl`.
    case codex
}

/// One thing in an agent's session, read from the harness's own log rather than its
/// screen: what the owner sent, what the agent said (markdown), its thinking, a tool it
/// called and that tool's result, or a notice ("Interrupted", "/compact").
///
/// Harness-neutral: Claude Code's and Codex's logs map onto the same entries. A tool's
/// result is its own entry pointing back at the call (`result.toolID`), because the two
/// are separate lines in the log and can land in different pages.
public struct SessionEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user
        case assistant
        case thinking
        case tool
        case toolResult = "tool_result"
        case notice
    }

    /// Stable across reads of the same file: a log line's own id plus the block index.
    public var id: String
    public var kind: Kind
    /// The user's prompt, the assistant's markdown, the thinking, or the notice.
    public var text: String?
    /// Images attached to a user prompt.
    public var images: Int?
    public var tool: SessionTool?
    public var result: SessionToolResult?
    /// ISO 8601, as the log wrote it.
    public var timestamp: String?
    /// The byte offset of the log line the entry came from (for paging).
    public var offset: Int

    public init(id: String, kind: Kind, text: String? = nil, images: Int? = nil, tool: SessionTool? = nil,
                result: SessionToolResult? = nil, timestamp: String? = nil, offset: Int = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.images = images
        self.tool = tool
        self.result = result
        self.timestamp = timestamp
        self.offset = offset
    }
}

/// A tool call, normalised: what kind of step it is, its one-line argument, and for an
/// edit the strings or diff lines a diff card draws.
public struct SessionTool: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case run, read, edit, write, search, fetch, task, other
    }

    /// The call id the result points back at.
    public var id: String
    /// The harness's tool name (`Bash`, `Edit`, `exec`, `apply_patch`).
    public var name: String
    public var kind: Kind
    /// One line: the command, the file, the pattern, the URL.
    public var argument: String
    /// The file an edit or write touches.
    public var path: String?
    /// Old and new strings of an Edit or MultiEdit.
    public var edits: [SessionEdit]?
    /// Unified diff lines (`+`, `-`, ` `), for a write or a patch.
    public var diff: [String]?
    /// A question form's questions (Claude Code's AskUserQuestion), so a past ask reads as
    /// questions and options rather than the call's raw text.
    public var questions: [SessionQuestion]?

    public init(id: String, name: String, kind: Kind, argument: String, path: String? = nil,
                edits: [SessionEdit]? = nil, diff: [String]? = nil, questions: [SessionQuestion]? = nil) {
        self.questions = questions
        self.id = id
        self.name = name
        self.kind = kind
        self.argument = argument
        self.path = path
        self.edits = edits
        self.diff = diff
    }
}

/// One question of a question form as the agent asked it.
public struct SessionQuestion: Codable, Equatable, Sendable {
    public var header: String?
    public var question: String
    public var options: [String]
    public var multiSelect: Bool

    public init(header: String? = nil, question: String, options: [String], multiSelect: Bool = false) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    enum CodingKeys: String, CodingKey {
        case header, question, options
        case multiSelect = "multi_select"
    }
}

public struct SessionAnswer: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct SessionEdit: Codable, Equatable, Sendable {
    public var old: String
    public var new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

public struct SessionToolResult: Codable, Equatable, Sendable {
    /// The call this answers (`SessionTool.id`).
    public var toolID: String
    public var output: String
    public var isError: Bool
    /// The applied patch as unified diff lines, when the harness recorded one.
    public var diff: [String]?
    /// The output was cut to `SessionLogLimits.toolOutput`.
    public var truncated: Bool?
    /// The owner said no to the call at its permission prompt (it never ran).
    public var denied: Bool?
    /// The harness refused the call itself ("Blocked: sleep 40 …"); it never ran.
    public var blocked: Bool?
    /// The call was allowed and running when the owner interrupted it. A harness writes the
    /// same words for this as for a denial; the host that saw the approval sets it.
    public var interrupted: Bool?
    /// An answered question form (Claude Code's AskUserQuestion): each question and the answer.
    public var answers: [SessionAnswer]?

    public init(toolID: String, output: String, isError: Bool = false, diff: [String]? = nil, truncated: Bool? = nil,
                denied: Bool? = nil) {
        self.toolID = toolID
        self.output = output
        self.isError = isError
        self.diff = diff
        self.truncated = truncated
        self.denied = denied
    }

    /// The harnesses' own words for a call the owner rejected at its prompt.
    public static func isDenial(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("the user doesn't want to proceed with this tool use")
            || text.hasPrefix("the user doesn't want to take this action")
            || text.hasPrefix("user rejected") || text.contains("rejected by user")
    }

    /// Claude Code's own refusal of a call (`<tool_use_error>Blocked: …`), not the owner's.
    public static func isHarnessBlock(_ output: String) -> Bool {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<tool_use_error>") { text = String(text.dropFirst("<tool_use_error>".count)) }
        return text.hasPrefix("Blocked: ") || text.hasPrefix("Blocked:")
    }

    enum CodingKeys: String, CodingKey {
        case toolID = "tool_id", output, isError = "is_error", diff, truncated, denied, blocked, interrupted, answers
    }
}

/// How much of a log a reader hands on: entries are for reading on a phone, not a copy
/// of the log.
public enum SessionLogLimits {
    /// A prompt, a reply or a notice.
    public static let text = 64 * 1024
    /// A tool's output.
    public static let toolOutput = 8 * 1024
    /// A diff or an edit's strings, in lines.
    public static let diffLines = 400
    /// A log line longer than this is skipped unread (pasted files, attachments).
    public static let line = 8 * 1024 * 1024

    static func clip(_ text: String, _ limit: Int = text) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var end = text.index(text.startIndex, offsetBy: min(text.count, limit))
        while text[..<end].utf8.count > limit { end = text.index(before: end) }
        return (String(text[..<end]), true)
    }

    static func clipLines(_ lines: [String]) -> [String] {
        lines.count > diffLines ? Array(lines.prefix(diffLines)) + ["… \(lines.count - diffLines) more lines"] : lines
    }
}

/// Reads one harness's log lines into entries. A reader sees one line at a time and
/// keeps no state between lines, so any page of a file reads the same way.
public protocol SessionLogReader: Sendable {
    var harness: SessionHarness { get }
    /// The entries one JSONL line holds (none for metadata and the harness's own context).
    func entries(line: [String: Any], offset: Int) -> [SessionEntry]
    /// A session title the line carries (Claude Code's `ai-title`, Codex's thread name).
    func title(line: [String: Any]) -> String?
}

public enum SessionLogReaders {
    public static func reader(_ harness: SessionHarness) -> any SessionLogReader {
        switch harness {
        case .claude: return ClaudeSessionReader()
        case .codex: return CodexSessionReader()
        }
    }
}

extension SessionTool.Kind {
    /// The kind of a tool by its common names across harnesses.
    static func of(_ name: String) -> SessionTool.Kind {
        switch name.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "run", "bashoutput", "powershell": return .run
        case "read", "view", "ls", "notebookread": return .read
        case "grep", "glob", "search", "find", "toolsearch": return .search
        case "edit", "multiedit", "notebookedit", "apply_patch", "update": return .edit
        case "write", "create": return .write
        case "webfetch", "websearch", "fetch", "web_search": return .fetch
        case "task", "agent": return .task
        default: return .other
        }
    }
}
