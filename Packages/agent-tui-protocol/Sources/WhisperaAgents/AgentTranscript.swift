// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// An agent's terminal output read as a conversation: what the owner sent, what the
/// agent said, the tools it ran, the question it is waiting on. Heuristic and lossless
/// enough for reading; the raw output is always one tap away.
///
/// Understands Claude Code's transcript marks (`> ` prompt, `⏺` message or tool call,
/// `⎿` tool result, a `╭…╰` box for a question) and Codex's `•` status lines. Anything
/// else is the agent talking.
public struct AgentTranscript: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        /// A prompt the owner sent.
        case prompt(String)
        /// The agent's prose.
        case message(String)
        /// A tool call: `Bash(python3 -m unittest)` and what it printed.
        case tool(name: String, argument: String, output: [String])
        /// The agent is waiting on an answer (a permission box).
        case question(title: [String], options: [String], selectedOption: Int? = nil)
        /// A one-line activity status ("Working (2m 14s · esc to interrupt)").
        case status(String)
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public init(parsing text: String) {
        items = Self.parse(text)
    }

    // MARK: Parsing

    private static let messageMark = "⏺"
    private static let resultMark = "⎿"

    public static func parse(_ text: String) -> [Item] {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lines = clean.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var items: [Item] = []
        var index = 0
        var prose: [String] = []

        func flushProse() {
            let body = trimBlankEdges(prose).joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.message(body))
            }
            prose = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushProse()
                index += 1
                continue
            }

            // A boxed question: ╭ … │ … ╰
            if trimmed.hasPrefix("╭") {
                flushProse()
                var inner: [String] = []
                index += 1
                while index < lines.count {
                    let boxLine = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if boxLine.hasPrefix("╰") { break }
                    inner.append(stripBox(boxLine))
                }
                items.append(question(from: inner))
                continue
            }

            // The owner's prompt: "> text", continued until a blank line or a mark.
            if trimmed.hasPrefix(">") {
                flushProse()
                var body = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                index += 1
                while index < lines.count, !isMarked(lines[index]),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    body.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let prompt = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty { items.append(.prompt(prompt)) }
                continue
            }

            // ⏺ a message or a tool call, with ⎿ results under it.
            if trimmed.hasPrefix(messageMark) {
                flushProse()
                let content = String(trimmed.dropFirst(messageMark.count)).trimmingCharacters(in: .whitespaces)
                index += 1
                if let call = toolCall(content) {
                    var output: [String] = []
                    while index < lines.count {
                        let next = lines[index]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        guard !nextTrimmed.isEmpty, !isMarked(next) || nextTrimmed.hasPrefix(resultMark),
                              next.hasPrefix(" ") || nextTrimmed.hasPrefix(resultMark)
                        else { break }
                        var body = nextTrimmed
                        if body.hasPrefix(resultMark) {
                            body = String(body.dropFirst(resultMark.count)).trimmingCharacters(in: .whitespaces)
                        }
                        output.append(body)
                        index += 1
                    }
                    items.append(.tool(name: call.name, argument: call.argument, output: output))
                } else {
                    prose = [content]
                    while index < lines.count, !isMarked(lines[index]),
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        prose.append(lines[index].trimmingCharacters(in: .whitespaces))
                        index += 1
                    }
                    flushProse()
                }
                continue
            }

            // Codex: "• Working (…)" is a status; other bullets are prose.
            if trimmed.hasPrefix("•") {
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isStatus(content) {
                    flushProse()
                    items.append(.status(content))
                    index += 1
                    continue
                }
            }

            prose.append(line.trimmingTrailingWhitespace())
            index += 1
        }
        flushProse()
        return items
    }

    /// Lines that start a new item.
    private static func isMarked(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(messageMark) || trimmed.hasPrefix(">") || trimmed.hasPrefix("╭")
            || trimmed.hasPrefix(resultMark) || (trimmed.hasPrefix("•") && isStatus(String(trimmed.dropFirst())))
    }

    private static func isStatus(_ content: String) -> Bool {
        let lowered = content.trimmingCharacters(in: .whitespaces).lowercased()
        return ["working", "thinking", "running", "waiting"].contains { lowered.hasPrefix($0) }
    }

    /// `Bash(python3 -m unittest)` → ("Bash", "python3 -m unittest"). Tool names are one
    /// word starting with a capital letter, so prose with parentheses stays prose.
    public static func toolCall(_ content: String) -> (name: String, argument: String)? {
        guard let open = content.firstIndex(of: "("), content.hasSuffix(")") else { return nil }
        let name = String(content[..<open])
        guard let first = name.first, first.isUppercase, !name.contains(" "), name.count <= 40,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" || $0 == ":" })
        else { return nil }
        let argument = String(content[content.index(after: open)..<content.index(before: content.endIndex)])
        return (name, argument)
    }

    private static func question(from inner: [String]) -> Item {
        var title: [String] = []
        var options: [String] = []
        var selectedOption: Int?
        for raw in inner {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let selected = line.hasPrefix("❯")
            if selected { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                if selected { selectedOption = options.count }
                options.append(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
            } else {
                title.append(line)
            }
        }
        return .question(title: title, options: options, selectedOption: selectedOption)
    }

    private static func stripBox(_ line: String) -> String {
        var line = line
        if line.hasPrefix("│") { line.removeFirst() }
        if line.hasSuffix("│") { line.removeLast() }
        return line.trimmingTrailingWhitespace()
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy.removeLast() }
        return copy
    }
}
