// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// One read of a question form on an agent's screen: which question is up, where the cursor
/// is, what is checked or typed. `AgentAskDriver` re-reads this between keys; `AgentAsk`
/// accumulates the questions across reads.
public struct AskScreen: Equatable, Sendable {
	public enum Dialect: String, Sendable { case claude, codex }

	public struct Tab: Equatable, Sendable {
		public var header: String
		public var answered: Bool
	}

	public struct Row: Equatable, Sendable {
		public var number: Int
		public var label: String
		public var description: String?
		/// A multi-select row's checkbox.
		public var checked: Bool
		/// A single-select row marked as the current answer (`✔` after the label).
		public var chosen: Bool
	}

	/// Where the cursor is, in the question's own terms.
	public enum Cursor: Equatable, Sendable {
		case option(Int)
		/// The free-text row (Claude's "Type something", Codex's "None of the above").
		case other
		/// Claude's multi-select "Next" / "Submit" row.
		case next
		/// Somewhere else, such as Claude's "Chat about this".
		case outside
	}

	public struct ReviewLine: Equatable, Sendable {
		public var question: String
		public var answer: String
	}

	public var dialect: Dialect
	/// One per question (Claude's tab headers; Codex has no headers).
	public var tabs: [Tab]
	public var hasSubmitStep: Bool
	/// The question index on screen, or `tabs.count` for the review step; nil when the
	/// screen does not say (Claude without ANSI colours).
	public var step: Int?
	public var isReview: Bool { step == tabs.count && hasSubmitStep || review != nil }

	// The question step.
	public var questionText: String?
	public var options: [Row]
	public var multiSelect: Bool
	public var otherLabel: String?
	/// Text typed into the free-text row (nil while it shows its placeholder).
	public var otherText: String?
	public var otherChecked: Bool
	public var hasNextRow: Bool
	public var cursor: Cursor?
	/// Codex: the notes field is open under the options.
	public var notesOpen: Bool

	// The review step.
	public var review: [ReviewLine]?
	/// Review buttons ("Submit answers", "Cancel") and the one under the cursor.
	public var reviewButtons: [String]
	public var reviewCursor: Int?

	public init(dialect: Dialect, tabs: [Tab]) {
		self.dialect = dialect
		self.tabs = tabs
		hasSubmitStep = false
		options = []
		multiSelect = false
		otherChecked = false
		hasNextRow = false
		notesOpen = false
		reviewButtons = []
	}

	/// The cursor's row index counting options, then the free-text row, then "Next".
	public var cursorRow: Int? {
		switch cursor {
		case .option(let index): return index
		case .other: return options.count
		case .next: return options.count + 1
		case .outside, nil: return nil
		}
	}
}

public enum AgentAskParser {
	/// The ask on screen: a question form, else a numbered or cursor menu, else nil.
	public static func ask(text: String, ansi: String? = nil) -> AgentAsk? {
		if let screen = screen(text: text, ansi: ansi) { return AgentAsk(screen: screen) }
		return ChoiceMenuParser.parse(text).map(AgentAsk.init(menu:))
	}

	/// A question form (Claude Code's AskUserQuestion, Codex's request_user_input) on screen.
	public static func screen(text: String, ansi: String? = nil) -> AskScreen? {
		let lines = normalized(text)
		return ClaudeAskParser.parse(lines, ansi: ansi.map(normalized)) ?? CodexAskParser.parse(lines)
	}

	/// The screen shows a question form, which is not a permission prompt.
	public static func isQuestionForm(_ text: String) -> Bool { screen(text: text) != nil }

	static func normalized(_ text: String) -> [String] {
		text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map { line in
			var line = Substring(line)
			while let last = line.last, last.isWhitespace { line = line.dropLast() }
			return String(line)
		}
	}

	static func stripANSI(_ text: String) -> String {
		text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
			.replacingOccurrences(of: "\u{001B}\\][^\u{0007}\u{001B}]*(\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression)
	}

	static func isHeavyRule(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.count >= 10 && trimmed.allSatisfy { $0 == "─" || $0 == "━" || $0 == "═" }
	}

	/// `❯ 2. Rust` → (cursor, 2, "Rust"); nil for any other line.
	static func numbered(_ line: String, cursors: Set<Character>) -> (cursor: Bool, number: Int, rest: String)? {
		var text = Substring(line).drop { $0 == " " }
		var cursor = false
		if let first = text.first, cursors.contains(first) {
			cursor = true
			text = text.dropFirst().drop { $0 == " " }
		}
		let digits = text.prefix { $0.isASCII && $0.isNumber }
		guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
		let after = text.dropFirst(digits.count)
		guard after.first == ".", after.dropFirst().first == " " else { return nil }
		return (cursor, number, String(after.dropFirst(2)))
	}

	/// The cells of an ANSI line: visible characters, each with whether it is highlighted
	/// (a background colour or reverse video).
	static func highlights(_ ansiLine: String) -> [(Character, Bool)] {
		var cells: [(Character, Bool)] = []
		var background = false
		var reverse = false
		var index = ansiLine.startIndex
		while index < ansiLine.endIndex {
			let char = ansiLine[index]
			if char == "\u{001B}" {
				let next = ansiLine.index(after: index)
				guard next < ansiLine.endIndex else { break }
				if ansiLine[next] == "[" {
					var end = ansiLine.index(after: next)
					while end < ansiLine.endIndex, !(("@"..."~").contains(ansiLine[end])) { end = ansiLine.index(after: end) }
					guard end < ansiLine.endIndex else { break }
					if ansiLine[end] == "m" {
						let params = ansiLine[ansiLine.index(after: next)..<end].split(separator: ";", omittingEmptySubsequences: false)
							.map { Int($0) ?? 0 }
						var i = 0
						let list = params.isEmpty ? [0] : params
						while i < list.count {
							switch list[i] {
							case 0: background = false; reverse = false
							case 7: reverse = true
							case 27: reverse = false
							case 49: background = false
							case 40...47, 100...107: background = true
							case 48:
								background = true
								i += (i + 1 < list.count && list[i + 1] == 5) ? 2 : 4
							case 38:
								i += (i + 1 < list.count && list[i + 1] == 5) ? 2 : 4
							default: break
							}
							i += 1
						}
					}
					index = ansiLine.index(after: end)
					continue
				}
				index = ansiLine.index(after: next)
				continue
			}
			if char != "\r" { cells.append((char, background || reverse)) }
			index = ansiLine.index(after: index)
		}
		return cells
	}
}

/// Claude Code's AskUserQuestion: a tab bar (`←  ☐ Language  ☒ Features  ✔ Submit  →`, or a
/// lone `☐ Color` for one question), the question, numbered options with descriptions, a
/// "Type something" row, "Next"/"Submit" for multi-select, then "Chat about this"; or the
/// "Review your answers" step with Submit / Cancel.
enum ClaudeAskParser {
	static let cursors: Set<Character> = ["❯"]
	static let placeholders: Set<String> = ["Type something.", "Type something"]

	static func parse(_ lines: [String], ansi: [String]?) -> AskScreen? {
		// A lone `☐ Color` bar (one question) sits right under the dialog's rule; Claude's todo
		// list draws the same boxes in the transcript.
		guard let headerIndex = lines.indices.last(where: { index in
			isTabBar(lines[index])
				&& (lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("←")
					|| (index > 0 && AgentAskParser.isHeavyRule(lines[index - 1])))
		}) else { return nil }
		let body = Array(lines[(headerIndex + 1)...])
		let isReview = body.contains { $0.trimmingCharacters(in: .whitespaces) == "Review your answers" }
		let isQuestion = body.contains { $0.contains("Enter to select") }
		guard isReview || isQuestion else { return nil }
		let (tabs, submit) = tabsOf(lines[headerIndex])
		guard !tabs.isEmpty, tabs.count <= 8 else { return nil }
		var screen = AskScreen(dialect: .claude, tabs: tabs)
		screen.hasSubmitStep = submit
		if isReview {
			guard submit, parseReview(body, into: &screen) else { return nil }
			screen.step = tabs.count
			return screen
		}
		guard parseQuestion(body, into: &screen) else { return nil }
		if tabs.count == 1, !submit {
			screen.step = 0
		} else if let ansi, let active = activeTab(lines[headerIndex], ansi: ansi, tabs: tabs) {
			screen.step = active
		}
		return screen
	}

	static func isTabBar(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if trimmed.hasPrefix("←"), trimmed.hasSuffix("→") {
			return trimmed.contains("☐") || trimmed.contains("☒")
		}
		return (trimmed.hasPrefix("☐ ") || trimmed.hasPrefix("☒ ")) && !trimmed.contains("  ☐") && trimmed.count <= 40
	}

	/// The question tabs (header, answered) and whether a Submit tab ends the bar.
	static func tabsOf(_ line: String) -> ([AskScreen.Tab], Bool) {
		var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
		if trimmed.hasPrefix("←") { trimmed = trimmed.dropFirst() }
		if trimmed.hasSuffix("→") { trimmed = trimmed.dropLast() }
		var tabs: [AskScreen.Tab] = []
		var submit = false
		var marker: Character?
		var label = ""
		func flush() {
			guard let marker else { return }
			let text = label.trimmingCharacters(in: .whitespaces)
			if marker == "✔" {
				if text == "Submit" { submit = true }
			} else if !text.isEmpty {
				tabs.append(AskScreen.Tab(header: text, answered: marker == "☒"))
			}
		}
		for char in trimmed {
			if char == "☐" || char == "☒" || char == "✔" {
				flush()
				marker = char
				label = ""
			} else {
				label.append(char)
			}
		}
		flush()
		return (tabs, submit)
	}

	/// The highlighted tab in the ANSI copy of the tab bar.
	static func activeTab(_ header: String, ansi: [String], tabs: [AskScreen.Tab]) -> Int? {
		let plain = header.trimmingCharacters(in: .whitespaces)
		guard let line = ansi.last(where: { AgentAskParser.stripANSI($0).trimmingCharacters(in: .whitespaces) == plain })
		else { return nil }
		let cells = AgentAskParser.highlights(line)
		let text = String(cells.map(\.0))
		var searchFrom = text.startIndex
		for (index, tab) in tabs.enumerated() {
			guard let range = text.range(of: tab.header, range: searchFrom..<text.endIndex) else { return nil }
			let start = text.distance(from: text.startIndex, to: range.lowerBound)
			let count = tab.header.count
			let lit = cells[start..<(start + count)].filter(\.1).count
			if lit * 2 > count { return index }
			searchFrom = range.upperBound
		}
		return nil
	}

	static func parseQuestion(_ body: [String], into screen: inout AskScreen) -> Bool {
		var i = 0
		while i < body.count, body[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
		var question: [String] = []
		while i < body.count, !body[i].trimmingCharacters(in: .whitespaces).isEmpty,
			AgentAskParser.numbered(body[i], cursors: cursors) == nil
		{
			question.append(body[i].trimmingCharacters(in: .whitespaces))
			i += 1
		}
		guard !question.isEmpty else { return false }
		screen.questionText = ungutter(question).joined(separator: " ")
		var rows: [(row: AskScreen.Row, cursor: Bool)] = []
		var nextCursor = false
		var outsideCursor = false
		while i < body.count {
			let line = body[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			i += 1
			if AgentAskParser.isHeavyRule(line) {
				// Below the rule: "Chat about this" and the footer.
				while i < body.count {
					if AgentAskParser.numbered(body[i], cursors: cursors)?.cursor == true { outsideCursor = true }
					i += 1
				}
				break
			}
			if trimmed.isEmpty { continue }
			if let option = AgentAskParser.numbered(line, cursors: cursors) {
				var label = option.rest
				var checked = false
				if label.hasPrefix("[ ] ") || label.hasPrefix("[✔] ") || label == "[ ]" || label == "[✔]" {
					screen.multiSelect = true
					checked = label.hasPrefix("[✔]")
					label = String(label.dropFirst(checked ? 3 : 3)).trimmingCharacters(in: .whitespaces)
				}
				var chosen = false
				if label.hasSuffix(" ✔") {
					chosen = true
					label = String(label.dropLast(2))
				}
				rows.append((AskScreen.Row(number: option.number, label: label, checked: checked, chosen: chosen), option.cursor))
				continue
			}
			let bare = trimmed.hasPrefix("❯") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
			if bare == "Next" || bare == "Submit", screen.multiSelect || rows.last?.row.label.hasPrefix("Type something") == true {
				screen.hasNextRow = true
				screen.multiSelect = true
				nextCursor = trimmed.hasPrefix("❯")
				continue
			}
			if let last = rows.indices.last {
				let joined = [rows[last].row.description, trimmed].compactMap { $0 }.joined(separator: " ")
				rows[last].row.description = joined
			}
		}
		// The last numbered row before the rule is the free-text row.
		guard rows.count >= 2, rows.enumerated().allSatisfy({ $0.element.row.number == $0.offset + 1 }) else { return false }
		let other = rows.removeLast()
		screen.otherLabel = "Type something"
		// Typed text replaces the placeholder; a long answer wraps onto the lines below it.
		screen.otherText = placeholders.contains(other.row.label)
			? nil : [other.row.label, other.row.description].compactMap { $0 }.joined(separator: " ")
		screen.otherChecked = other.row.checked
		screen.options = rows.map(\.row)
		if let index = rows.firstIndex(where: \.cursor) {
			screen.cursor = .option(index)
		} else if other.cursor {
			screen.cursor = .other
		} else if nextCursor {
			screen.cursor = .next
		} else if outsideCursor {
			screen.cursor = .outside
		}
		return true
	}

	/// Claude Code draws a dim `│` gutter left of a question that is multi-line or wider than
	/// 80 columns, on the question step and in the review. The bar is decoration, not text.
	static func ungutter(_ lines: [String]) -> [String] {
		guard lines.allSatisfy({ gutter($0) != nil }) else { return lines }
		return lines.map { gutter($0)! }.filter { !$0.isEmpty }
	}

	/// The line without a leading `│` gutter (trimmed), or nil when it has none.
	static func gutter(_ line: String) -> String? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.first == "│" else { return nil }
		return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
	}

	static func parseReview(_ body: [String], into screen: inout AskScreen) -> Bool {
		var lines: [AskScreen.ReviewLine] = []
		var buttons: [String] = []
		var cursor: Int?
		// A question or answer too wide for the pane wraps onto the lines below it.
		enum Part { case none, question, answer }
		var part = Part.none
		for line in body {
			let raw = line.trimmingCharacters(in: .whitespaces)
			let trimmed = gutter(line) ?? raw
			if trimmed.hasPrefix("● ") {
				lines.append(AskScreen.ReviewLine(question: String(trimmed.dropFirst(2)), answer: ""))
				part = .question
			} else if trimmed.hasPrefix("→ "), let last = lines.indices.last {
				lines[last].answer = String(trimmed.dropFirst(2))
				part = .answer
			} else if let option = AgentAskParser.numbered(line, cursors: cursors) {
				if option.cursor { cursor = buttons.count }
				buttons.append(option.rest)
				part = .none
			} else if trimmed.isEmpty {
				// A blank row inside the gutter is still the same question.
				if gutter(line) == nil { part = .none }
			} else if let last = lines.indices.last {
				switch part {
				case .question: lines[last].question += " " + trimmed
				case .answer: lines[last].answer += " " + trimmed
				case .none: break
				}
			}
		}
		guard buttons.contains(where: { $0.hasPrefix("Submit") }) else { return false }
		screen.review = lines
		screen.reviewButtons = buttons
		screen.reviewCursor = cursor
		return true
	}
}

/// Codex's request_user_input: `Question 1/2 (2 unanswered)`, the question, numbered options
/// with a description column, "None of the above" (notes with Tab), and a footer naming
/// `enter to submit answer` / `enter to submit all`.
enum CodexAskParser {
	static let cursors: Set<Character> = ["›"]
	static let otherLabel = "None of the above"

	static func parse(_ lines: [String]) -> AskScreen? {
		guard let footer = lines.lastIndex(where: { $0.contains("enter to submit answer") || $0.contains("enter to submit all") }),
			let head = lines[..<footer].lastIndex(where: { questionHead($0) != nil }),
			let (number, total, unanswered) = questionHead(lines[head]), (1...8).contains(total), (1...total).contains(number)
		else { return nil }
		var tabs = (0..<total).map { _ in AskScreen.Tab(header: "", answered: false) }
		// Codex counts unanswered questions without naming them.
		if unanswered == 0 { for index in tabs.indices { tabs[index].answered = true } }
		var screen = AskScreen(dialect: .codex, tabs: tabs)
		screen.step = number - 1
		var i = head + 1
		var question: [String] = []
		while i < footer, AgentAskParser.numbered(lines[i], cursors: cursors) == nil {
			let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
			if !trimmed.isEmpty { question.append(trimmed) }
			i += 1
		}
		guard !question.isEmpty else { return nil }
		screen.questionText = question.joined(separator: " ")
		var rows: [(row: AskScreen.Row, cursor: Bool)] = []
		while i < footer {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			i += 1
			if let option = AgentAskParser.numbered(line, cursors: cursors) {
				let (label, description) = split(option.rest)
				rows.append((AskScreen.Row(number: option.number, label: label, description: description, checked: false, chosen: false), option.cursor))
			} else if trimmed.hasPrefix("›") {
				screen.notesOpen = true
				let notes = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
				screen.otherText = notes == "Add notes" || notes.isEmpty ? nil : notes
			} else if !trimmed.isEmpty, let last = rows.indices.last, !screen.notesOpen, line.hasPrefix("      ") {
				rows[last].row.description = [rows[last].row.description, trimmed].compactMap { $0 }.joined(separator: " ")
			}
		}
		guard rows.count >= 1, rows.enumerated().allSatisfy({ $0.element.row.number == $0.offset + 1 }) else { return nil }
		if let last = rows.last, last.row.label == otherLabel {
			rows.removeLast()
			screen.otherLabel = otherLabel
			if last.cursor { screen.cursor = .other }
		}
		screen.options = rows.map(\.row)
		if let index = rows.firstIndex(where: \.cursor) { screen.cursor = .option(index) }
		return screen
	}

	/// `Question 1/2 (2 unanswered)` → (1, 2, 2).
	static func questionHead(_ line: String) -> (Int, Int, Int?)? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.hasPrefix("Question ") else { return nil }
		let rest = trimmed.dropFirst("Question ".count)
		let parts = rest.split(separator: " ", maxSplits: 1)
		let fraction = parts.first?.split(separator: "/") ?? []
		guard fraction.count == 2, let number = Int(fraction[0]), let total = Int(fraction[1]) else { return nil }
		var unanswered: Int?
		if parts.count == 2, parts[1].hasPrefix("("), let value = Int(parts[1].dropFirst().prefix { $0.isNumber }) {
			unanswered = value
		} else if parts.count == 1 {
			unanswered = 0
		}
		return (number, total, unanswered)
	}

	/// `Swift              Use Swift.` → ("Swift", "Use Swift.").
	static func split(_ rest: String) -> (String, String?) {
		guard let gap = rest.range(of: "  ") else { return (rest, nil) }
		let label = String(rest[..<gap.lowerBound]).trimmingCharacters(in: .whitespaces)
		let description = String(rest[gap.upperBound...]).trimmingCharacters(in: .whitespaces)
		return (label, description.isEmpty ? nil : description)
	}
}

extension AgentAsk {
	/// The ask as far as one screen shows it: the question on screen is read, the others
	/// are known by header only.
	public init(screen: AskScreen) {
		let count = screen.tabs.count
		var questions = screen.tabs.map { tab in
			Question(header: tab.header.isEmpty ? nil : tab.header, text: "", options: [], answered: tab.answered)
		}
		let source: Source = screen.dialect == .claude ? .claude : .codex
		self.init(source: source, kind: .single, questions: questions, hasSubmitStep: screen.hasSubmitStep)
		if let index = screen.questionIndex ?? (count == 1 ? 0 : nil) {
			questions[index] = screen.question(header: questions[index].header, answered: questions[index].answered)
			self.questions = questions
		}
		step = screen.isReview ? count : (screen.step ?? 0)
		kind = count > 1 ? .form : (questions.first?.multiSelect == true ? .multi : .single)
		refreshIdentity()
	}

	/// Folds a new read of the screen into the ask. False when the screen shows a different
	/// ask (other headers, or a question that does not match the one read before).
	@discardableResult
	public mutating func merge(_ screen: AskScreen) -> Bool {
		let source: Source = screen.dialect == .claude ? .claude : .codex
		guard source == self.source, screen.tabs.count == questions.count, screen.hasSubmitStep == hasSubmitStep,
			zip(screen.tabs, questions).allSatisfy({ Self.sameHeader($0.header.isEmpty ? nil : $0.header, $1.header) })
		else { return false }
		for (index, tab) in screen.tabs.enumerated() where screen.dialect == .claude {
			questions[index].answered = tab.answered
			questions[index].header = Self.fullerHeader(questions[index].header, tab.header)
		}
		if screen.isReview {
			step = questions.count
		} else if let text = screen.questionText {
			// The question text wins over the tab colours: two captures (plain, ANSI) a moment
			// apart can disagree while the form redraws.
			let byText = questions.firstIndex { $0.text == text }
			var index = screen.step ?? byText ?? questions.firstIndex { !$0.isRead }
			if let step = screen.step, questions.indices.contains(step), questions[step].isRead, questions[step].text != text {
				index = byText
			}
			guard let index, questions.indices.contains(index) else { return false }
			let read = screen.question(header: questions[index].header, answered: questions[index].answered)
			if questions[index].isRead {
				guard questions[index].text == read.text, questions[index].options.map(\.label) == read.options.map(\.label)
				else { return false }
			} else {
				questions[index] = read
			}
			step = index
		}
		kind = questions.count > 1 ? .form : (questions.first?.multiSelect == true ? .multi : .single)
		refreshIdentity()
		return true
	}
}

extension AgentAsk {
	/// Two reads of one tab's header. A pane narrower than the tab bar clips every header but
	/// the active one ("Compan…" beside "Companion"), and which ones depends on the tab shown.
	public static func sameHeader(_ a: String?, _ b: String?) -> Bool {
		guard let a, let b else { return a == b }
		if a == b { return true }
		func stem(_ text: String) -> String? { text.hasSuffix("…") ? String(text.dropLast()) : nil }
		if let short = stem(a), !short.isEmpty, b.hasPrefix(short) || (stem(b).map { short.hasPrefix($0) || $0.hasPrefix(short) } ?? false) {
			return true
		}
		if let short = stem(b), !short.isEmpty, a.hasPrefix(short) { return true }
		return false
	}

	/// The header to keep: the one the screen shows in full, else the longer clipped one.
	static func fullerHeader(_ known: String?, _ shown: String) -> String? {
		guard !shown.isEmpty else { return known }
		guard let known, known != shown else { return shown }
		if known.hasSuffix("…"), !shown.hasSuffix("…") { return shown }
		if shown.hasSuffix("…"), !known.hasSuffix("…") { return known }
		return shown.count > known.count ? shown : known
	}
}

extension AskScreen {
	/// The question index on screen when it is known.
	var questionIndex: Int? {
		guard !isReview, let step, step < tabs.count else { return nil }
		return step
	}

	func question(header: String?, answered: Bool) -> AgentAsk.Question {
		AgentAsk.Question(
			header: header, text: questionText ?? "",
			options: options.enumerated().map { index, row in
				AgentAsk.Option(id: String(index + 1), label: row.label, description: row.description)
			},
			multiSelect: multiSelect, allowsOther: otherLabel != nil, otherLabel: otherLabel, answered: answered)
	}
}
