// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import CryptoKit
import Foundation

/// A numbered or cursor menu an agent is blocked on (a permission dialog, a trust prompt, a
/// picker), parsed from its terminal (moved here from the Whispera Mac helper, roadmap R1).
/// herdr only says `agent_status: "blocked"` and hands over the screen text; the dialog's structure is recovered here so the phone
/// gets a question and a closed list of options, and the keys for an option are chosen on
/// the Mac, never by the phone.
public struct ChoiceMenu: Equatable, Sendable {
	public enum Kind: String, Sendable, Codable { case approve, deny, other }

	/// What the dialog is. Only a `permission` asks to approve or deny a tool call; the others
	/// are answered with their own labels and carry no approve/deny meaning.
	public enum Purpose: String, Sendable, Codable {
		/// A tool call waiting for approval (Bash, Edit, Write, WebFetch, a Codex command or patch).
		case permission
		/// A startup dialog asking whether to trust the working folder.
		case trust
		/// An update or other notice (Codex's "Update available").
		case notice
		/// Any other menu or picker.
		case menu
	}

	/// What a permission prompt wants to do, split out of the dialog for display.
	public enum Action: String, Sendable, Codable { case run, edit, fetch, other }

	public struct Option: Equatable, Sendable {
		/// `"1"`, `"2"`, … in screen order: what the phone sends back as `choice`.
		public var id: String
		public var label: String
		/// `approve` / `deny` / `other` for a permission; always `other` for the other purposes.
		public var kind: Kind
		/// The number printed before the label (`1. Yes`), when there is one.
		public var number: Int?
		/// Choosing it ends the session or quits the agent ("No, exit", "Quit"): confirm first.
		public var destructive: Bool

		public init(id: String, label: String, kind: Kind, number: Int? = nil, destructive: Bool = false) {
			self.id = id
			self.label = label
			self.kind = kind
			self.number = number
			self.destructive = destructive
		}
	}

	public var title: String?
	public var question: String
	public var detail: String?
	public var options: [Option]
	/// Which option the terminal's cursor (`❯`, `›`) is on, when the screen shows it.
	public var selectedIndex: Int?
	/// The key the dialog's footer names for cancelling (`Esc to cancel`).
	public var cancelKey: String?
	public var purpose: Purpose
	/// A permission's action, tool ("Bash", "Edit", "Command"…), one-line description
	/// ("Run calc.py"), shell command, file and diff preview, when the dialog shows them.
	public var action: Action?
	public var tool: String?
	public var summary: String?
	public var command: String?
	public var file: String?
	public var diff: String?

	public init(
		title: String? = nil, question: String, detail: String? = nil, options: [Option], selectedIndex: Int? = nil,
		cancelKey: String? = nil, purpose: Purpose = .permission
	) {
		self.title = title
		self.question = question
		self.detail = detail
		self.options = options
		self.selectedIndex = selectedIndex
		self.cancelKey = cancelKey
		self.purpose = purpose
	}

	public var isPermission: Bool { purpose == .permission }

	/// Identifies this dialog (not the cursor position): a choice is only sent while the
	/// screen still shows the dialog the phone answered.
	public var id: String {
		var parts = [title ?? "", question, detail ?? ""]
		parts += options.map { "\($0.id)\u{1F}\($0.label)" }
		let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))
		return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	public static let maxOptions = 9

	/// The keys that pick `choice` and confirm it. With the cursor on screen: arrows from it
	/// to the option, then Enter (Claude Code and Codex lists both work this way). Without a
	/// cursor only a numbered option can be picked, by its digit.
	public func keys(for choice: String) -> [String]? {
		guard let target = options.firstIndex(where: { $0.id == choice }) else { return nil }
		if let selectedIndex {
			let delta = target - selectedIndex
			let moves = Array(repeating: delta > 0 ? "down" : "up", count: abs(delta))
			return moves + ["enter"]
		}
		if let number = options[target].number, (1...9).contains(number) { return [String(number)] }
		return nil
	}
}

/// Recovers a `ChoiceMenu` from herdr's plain-text screen. Best effort: anything it
/// cannot read with confidence is nil, and the phone falls back to the raw screen and keys.
public enum ChoiceMenuParser {
	public static let cursors: Set<Character> = ["❯", "›", "▶", "▸", "→"]
	static let borders: Set<Character> = ["│", "┃", "║", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]
	static let rules: Set<Character> = ["─", "━", "═", "╌", "┄", "┈", "╍", "-", "╴", "╶"]
	/// A full-width rule of these, or a box's top edge, starts the dialog.
	static let heavyRules: Set<Character> = ["─", "━", "═"]
	static let maxDetailLines = 12
	static let maxText = 600
	/// Lines this long were most likely wrapped by the terminal.
	static let wrapWidth = 70

	struct Line {
		var text: String
		var indent: Int
	}

	public static func parse(_ screen: String) -> ChoiceMenu? {
		let (region, ruled) = promptRegion(screen)
		guard let block = optionBlock(region) else { return nil }
		let before = Array(region[..<block.start])
		let after = region[block.end...].map(\.text).joined(separator: "\n").lowercased()
		// A prompt echoed in the transcript ("❯ run this…" with its wrapped lines) looks like a
		// cursor list: only a real dialog names its keys below the options.
		if block.options.allSatisfy({ $0.number == nil }), !hasKeyHint(after) { return nil }

		// Each non-empty line with its paragraph number (paragraphs split at blank lines).
		var lines = paragraphs(before).enumerated().flatMap { index, group in group.map { (text: $0, group: index) } }
		guard !lines.isEmpty else { return nil }
		// Without a rule the question is in one of the two paragraphs above the options, not
		// in a transcript line further up.
		let near = (lines.last?.group ?? 0) - 1
		func isQuestion(_ line: (text: String, group: Int)) -> Bool { line.text.contains("?") && (ruled || line.group >= near) }
		let mark = lines.lastIndex(where: isQuestion) ?? lines.count - 1
		if !ruled {
			// Without a rule or box above it the dialog's top is unknown: it starts at its question's paragraph.
			let group = lines[mark].group
			lines.removeAll { $0.group < group }
		}
		let q = lines.lastIndex(where: isQuestion) ?? lines.count - 1
		// A question wrapped across full-width lines keeps its other lines.
		var first = q
		while first > 0, lines[first - 1].group == lines[q].group, lines[first - 1].text.count >= wrapWidth { first -= 1 }
		var last = q
		if lines[q].text.count >= wrapWidth {
			while last + 1 < lines.count, lines[last + 1].group == lines[q].group { last += 1 }
		}
		let question = clip(lines[first...last].map(\.text).joined(separator: " "))
		// The spinner or turn-status line ("✻ Sautéed for 3s") is never a dialog's question.
		if isStatusLine(question), !hasKeyHint(after) { return nil }
		var title: String?
		var restStart = 0
		if ruled, first > 0 {
			title = clip(lines[0].text)
			restStart = 1
		}
		let rest = (lines[..<first].dropFirst(restStart) + lines[(last + 1)...]).map(\.text)
			.filter { !$0.lowercased().hasPrefix("tip:") }
		let detail = rest.prefix(maxDetailLines).joined(separator: "\n")

		var cancel: String?
		if after.contains("esc to cancel") || after.contains("esc to exit") { cancel = "esc" }
		let options = block.options.enumerated().map { index, option in
			ChoiceMenu.Option(
				id: String(index + 1), label: clip(option.label), kind: kind(of: option.label), number: option.number)
		}
		var menu = ChoiceMenu(
			title: title, question: question, detail: detail.isEmpty ? nil : clip(detail), options: options,
			selectedIndex: block.selected, cancelKey: cancel)
		classify(&menu, raw: rawRegion(screen), before: before.map(\.text))
		return menu
	}

	/// The footer a real dialog draws under its options ("Enter to confirm · Esc to cancel",
	/// "Press enter to continue", "↑/↓ to navigate").
	static func hasKeyHint(_ footer: String) -> Bool {
		let text = footer.lowercased()
		return ["esc to", "enter to", "press enter", "to navigate", "to select", "to confirm", "↑", "↓", "tab to", "enter continue",
				"esc quit"].contains(where: text.contains)
	}

	/// Claude Code's spinner and turn-status lines: a glyph, then a verb ("✻ Sautéed for 3s",
	/// "· Architecting…", "✢ Symbioting… (5s · ↓ 94 tokens)").
	static func isStatusLine(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard let first = trimmed.first, "✻✢✳✶✽✺·*⏺".contains(first) else { return false }
		let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
		guard let word = rest.split(separator: " ").first, word.first?.isUppercase == true else { return false }
		return rest.contains("…") || rest.range(of: #"\bfor \d+(\.\d+)?[smh]\b"#, options: .regularExpression) != nil
			|| word.hasSuffix("ed") || word.hasSuffix("ing")
	}

	// MARK: Purpose

	/// What a dialog is, from its text and option labels alone (hosts that only have a parsed
	/// dialog, such as a phone talking to an older Mac, use the same rules).
	public static func purpose(title: String?, question: String, detail: String?, labels: [String]) -> ChoiceMenu.Purpose {
		let text = [title ?? "", question, detail ?? ""].joined(separator: "\n").lowercased()
		let lower = labels.map { $0.lowercased() }
		let trust = ["trust this folder", "trust these files", "do you trust", "accessing workspace", "folder access", "trust the files"]
		if trust.contains(where: text.contains) || lower.contains(where: { $0.contains("trust") }) { return .trust }
		let notice = ["update available", "release notes", "what's new", "new version"]
		if notice.contains(where: text.contains)
			|| lower.contains(where: { $0.hasPrefix("update now") || $0.contains("skip until next version") })
		{
			return .notice
		}
		let kinds = labels.map(kind(of:))
		return kinds.contains(.approve) && kinds.contains(.deny) ? .permission : .menu
	}

	/// An option that quits the agent or ends its session.
	public static func isDestructive(_ label: String, purpose: ChoiceMenu.Purpose) -> Bool {
		guard purpose != .permission else { return false }
		let text = label.lowercased()
		for prefix in ["no, exit", "exit", "quit", "no, quit"] where text == prefix || text.hasPrefix(prefix + " ") || text.hasPrefix(prefix + ",") {
			return true
		}
		// Declining a folder-trust check exits Codex or Claude Code (or leaves the session).
		return purpose == .trust && kind(of: label) != .approve && !text.contains("trust")
	}

	static func classify(_ menu: inout ChoiceMenu, raw: [String], before: [String]) {
		let purpose = purpose(title: menu.title, question: menu.question, detail: menu.detail, labels: menu.options.map(\.label))
		menu.purpose = purpose
		if purpose == .notice, !menu.question.lowercased().contains("update available"),
			let headline = ([menu.title] + (menu.detail?.components(separatedBy: "\n") ?? []))
				.compactMap({ $0 }).first(where: { $0.lowercased().contains("update available") })
		{
			// Codex's notice has no question: its headline says what it is.
			let rest = (menu.detail?.components(separatedBy: "\n") ?? []).filter { $0 != headline }
			menu.detail = ([menu.question] + rest).joined(separator: "\n")
			menu.question = headline
		}
		guard purpose == .permission else {
			// No approve/deny semantics: the phone shows the agent's own labels.
			menu.options = menu.options.map { option in
				var option = option
				option.kind = .other
				option.destructive = isDestructive(option.label, purpose: purpose)
				return option
			}
			return
		}
		if let title = menu.title, describeClaude(&menu, title: title, raw: raw) { return }
		describeCodex(&menu, before: before, raw: raw)
	}

	/// Joins lines the terminal wrapped: one within a word's length of `width` continues on the next.
	static func joinWrapped(_ lines: [String], width: Int) -> [String] {
		guard width > 20 else { return lines }
		var joined: [String] = []
		var wrapped = false
		for line in lines {
			if wrapped, let last = joined.popLast() { joined.append(last + " " + line) } else { joined.append(line) }
			wrapped = line.count >= width - 14
		}
		return joined
	}

	static func isDashed(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.count >= 3 && trimmed.allSatisfy { "╌┄┈╍╴╶".contains($0) }
	}

	/// Claude Code: a title ("Bash command", "Edit file"), its description or file name, a
	/// dashed box with the command or the diff, then "This command requires approval".
	static func describeClaude(_ menu: inout ChoiceMenu, title: String, raw: [String]) -> Bool {
		var sections: [[String]] = [[]]
		for line in raw {
			if isDashed(line) { sections.append([]) } else { sections[sections.count - 1].append(line) }
		}
		guard sections.count >= 3 else { return false }
		// The dashed separators span the pane: a header line about that long was wrapped.
		let width = raw.first(where: isDashed)?.trimmingCharacters(in: .whitespaces).count ?? 0
		let header = joinWrapped(sections[0].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, width: width)
		guard header.first == title else { return false }
		let rest = header.dropFirst().filter { !$0.lowercased().hasPrefix("tip:") }
		let body = trimCommonIndent(sections[1])
		let lower = title.lowercased()
		if lower.contains("edit") || lower.contains("create") || lower.contains("write") || lower.contains("file") {
			menu.action = .edit
			menu.tool = lower.contains("create") || lower.contains("write") ? "Write" : "Edit"
			menu.file = rest.first
			menu.diff = body.isEmpty ? nil : clip(body.joined(separator: "\n"), limit: 4000)
		} else {
			let fetch = lower.contains("fetch") || lower.contains("web")
			menu.action = fetch ? .fetch : lower.contains("bash") || lower.contains("command") ? .run : .other
			menu.tool = fetch ? "WebFetch" : lower.contains("bash") ? "Bash" : title
			menu.summary = rest.isEmpty ? nil : clip(rest.joined(separator: " "))
			let command = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			menu.command = command.isEmpty ? nil : clip(command, limit: 2000)
		}
		// The detail an older phone shows: the command (or file) first, without the boilerplate.
		let detail = [menu.command ?? menu.file, menu.summary].compactMap { $0 }.joined(separator: "\n")
		if !detail.isEmpty { menu.detail = detail }
		return true
	}

	/// Codex: "Would you like to run the following command?" with `Reason:` and `$ command`,
	/// or "Would you like to make the following edits?" with `Destination:` and the patch
	/// drawn above the dialog (`• Edited calc.py (+4 -0)`).
	static func describeCodex(_ menu: inout ChoiceMenu, before: [String], raw: [String]) {
		let lines = before.map { $0.trimmingCharacters(in: .whitespaces) }
		guard let ask = lines.lastIndex(where: { $0.hasPrefix("Would you like to") || $0.hasPrefix("Do you want to") }) else { return }
		let question = lines[ask]
		let after = lines[(ask + 1)...]
		func field(_ name: String) -> String? {
			after.first { $0.hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
		}
		menu.question = question
		let lower = question.lowercased()
		if lower.contains("edit") || lower.contains("patch") || lower.contains("change") {
			menu.action = .edit
			menu.tool = "Edit"
			if let destination = field("Destination") { menu.file = (destination as NSString).lastPathComponent }
			menu.summary = field("Reason")
			menu.diff = codexDiff(raw)
		} else {
			menu.action = lower.contains("command") || lower.contains("run") ? .run : .other
			menu.tool = "Command"
			menu.summary = field("Reason")
			if let command = after.first(where: { $0.hasPrefix("$ ") }) { menu.command = clip(String(command.dropFirst(2))) }
		}
		let detail = [menu.command ?? field("Destination"), menu.summary].compactMap { $0 }.joined(separator: "\n")
		if !detail.isEmpty { menu.detail = clip(detail) }
	}

	/// The numbered patch lines under the last `• Edited`/`• Proposed` item on screen.
	static func codexDiff(_ raw: [String]) -> String? {
		guard let start = raw.lastIndex(where: {
			let t = $0.trimmingCharacters(in: .whitespaces)
			return t.hasPrefix("• Edited ") || t.hasPrefix("• Proposed ") || t.hasPrefix("• Added ") || t.hasPrefix("• Deleted ")
		}) else { return nil }
		var body: [String] = []
		for line in raw[(start + 1)...] {
			let t = line.trimmingCharacters(in: .whitespaces)
			guard let first = t.first, first.isNumber else { break }
			body.append(line)
		}
		let trimmed = trimCommonIndent(body)
		return trimmed.isEmpty ? nil : clip(trimmed.joined(separator: "\n"), limit: 4000)
	}

	static func trimCommonIndent(_ lines: [String]) -> [String] {
		var lines = lines.map { line -> String in
			var text = Substring(line)
			while let last = text.last, last == " " || borders.contains(last) { text = text.dropLast() }
			if let first = text.first, borders.contains(first) { text = text.dropFirst() }
			return String(text)
		}
		while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
		while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
		let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			.map { $0.prefix { $0 == " " }.count }.min() ?? 0
		return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
	}

	/// The dialog's lines as drawn (dashed separators kept), from the same top as `promptRegion`.
	static func rawRegion(_ screen: String) -> [String] {
		let raw = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
		return Array(raw[regionStart(raw).start...])
	}

	/// The dialog sits below the screen's last full-width rule (Claude Code draws one above
	/// it); without a rule, the bottom of the screen.
	static func promptRegion(_ screen: String) -> (lines: [Line], ruled: Bool) {
		let raw = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
		let (start, ruled) = regionStart(raw)
		let lines = raw[start...].compactMap { line -> Line? in
			var text = Substring(line)
			while let first = text.first, first == " " || borders.contains(first) { text = text.dropFirst() }
			let indent = line.count - text.count
			while let last = text.last, last == " " || borders.contains(last) { text = text.dropLast() }
			if !text.isEmpty, isRule(String(text), minimum: 3) { return nil }
			return Line(text: String(text), indent: indent)
		}
		return (lines, ruled)
	}

	static func regionStart(_ raw: [String]) -> (start: Int, ruled: Bool) {
		var start = max(0, raw.count - 40)
		var rule = raw.lastIndex { isDialogTop($0) }
		// A box that closes above the options (Codex's update notice) is not the dialog.
		if let top = rule, let edge = raw[top].trimmingCharacters(in: .whitespaces).first, edge == "╭" || edge == "┌",
			let close = raw[(top + 1)...].firstIndex(where: { line in
				let first = line.trimmingCharacters(in: .whitespaces).first
				return first == "╰" || first == "└"
			}),
			raw[(close + 1)...].contains(where: { option(Line(text: $0.trimmingCharacters(in: .whitespaces), indent: 0)) != nil })
		{
			rule = nil
			start = max(close + 1, raw.count - 40)
		}
		if let rule { start = rule + 1 }
		return (start, rule != nil)
	}

	static func isDialogTop(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.count >= 10 else { return false }
		if let first = trimmed.first, first == "╭" || first == "┌" {
			return trimmed.dropFirst().dropLast().allSatisfy(heavyRules.contains)
		}
		return trimmed.allSatisfy(heavyRules.contains)
	}

	static func isRule(_ line: String, minimum: Int) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.count >= minimum && trimmed.allSatisfy { rules.contains($0) || borders.contains($0) }
			&& trimmed.contains { $0 != "-" && rules.contains($0) }
	}

	struct ParsedOption {
		var label: String
		var number: Int?
		var cursor: Bool
		var column: Int
	}

	struct Block {
		var start: Int
		var end: Int
		var options: [(label: String, number: Int?)]
		var selected: Int?
	}

	/// `❯ 1. Yes` / `  2. No` / `› Allow` → label, number, cursor and the label's column.
	static func option(_ line: Line) -> ParsedOption? {
		var text = Substring(line.text)
		var column = line.indent
		var cursor = false
		if let first = text.first, cursors.contains(first) || (first == ">" && text.dropFirst().first == " ") {
			cursor = true
			text = text.dropFirst()
			column += 1
			while text.first == " " {
				text = text.dropFirst()
				column += 1
			}
		}
		var number: Int?
		let digits = text.prefix { $0.isASCII && $0.isNumber }
		if (1...2).contains(digits.count), let value = Int(digits) {
			let afterDigits = text.dropFirst(digits.count)
			if let mark = afterDigits.first, mark == "." || mark == ")", afterDigits.dropFirst().first == " " {
				number = value
				text = afterDigits.dropFirst().drop { $0 == " " }
			}
		}
		let label = text.trimmingCharacters(in: .whitespaces)
		guard !label.isEmpty, number != nil || cursor else { return nil }
		return ParsedOption(label: label, number: number, cursor: cursor, column: column)
	}

	/// The last run of options on screen: numbered `1.`…`n.` lines, or an unnumbered list
	/// around a cursor line whose labels share the cursor label's column.
	static func optionBlock(_ lines: [Line]) -> Block? {
		var index = lines.count - 1
		while index >= 0 {
			if option(lines[index])?.number != nil, let block = numberedBlock(lines, endingAt: index) { return block }
			index -= 1
		}
		guard let cursorIndex = lines.lastIndex(where: { option($0)?.cursor == true }),
			let cursor = option(lines[cursorIndex]), cursor.number == nil
		else { return nil }
		func member(_ i: Int) -> Bool {
			let line = lines[i]
			guard !line.text.isEmpty else { return false }
			return line.indent == cursor.column || i == cursorIndex
		}
		var start = cursorIndex
		while start > 0, member(start - 1) { start -= 1 }
		var end = cursorIndex + 1
		while end < lines.count, member(end) { end += 1 }
		let options = (start..<end).map { i in (label: i == cursorIndex ? cursor.label : lines[i].text, number: Int?.none) }
		guard (2...ChoiceMenu.maxOptions).contains(options.count) else { return nil }
		return Block(start: start, end: end, options: options, selected: cursorIndex - start)
	}

	/// Numbered options ending at `last`, walking up to `1.`; a wrapped label's continuation
	/// lines (indented past the number) join the option above them.
	static func numberedBlock(_ lines: [Line], endingAt last: Int) -> Block? {
		var collected: [(label: String, number: Int, cursor: Bool, line: Int)] = []
		var continuation: [String] = []
		var i = last
		while i >= 0 {
			let line = lines[i]
			if let parsed = option(line), let number = parsed.number {
				let label = ([parsed.label] + continuation.reversed()).joined(separator: " ")
				continuation = []
				if let previous = collected.last, previous.number != number + 1 { break }
				collected.append((label, number, parsed.cursor, i))
				if number == 1 { break }
			} else if !line.text.isEmpty, !collected.isEmpty || i == last, line.indent >= 4 {
				continuation.append(line.text)
			} else {
				break
			}
			i -= 1
		}
		guard let first = collected.last, first.number == 1, collected.count >= 2,
			collected.count <= ChoiceMenu.maxOptions
		else { return nil }
		var ordered = Array(collected.reversed())
		let selected = ordered.firstIndex { $0.cursor }
		// The last option's own wrapped lines sit below it.
		var end = last + 1
		if let column = option(lines[last])?.column {
			while end < lines.count, !lines[end].text.isEmpty, option(lines[end]) == nil, lines[end].indent >= column {
				ordered[ordered.count - 1].label += " " + lines[end].text
				end += 1
			}
		}
		return Block(
			start: first.line, end: end,
			options: ordered.map { (label: $0.label, number: Int?.some($0.number)) }, selected: selected)
	}

	/// Non-empty lines grouped by blank lines.
	static func paragraphs(_ lines: [Line]) -> [[String]] {
		var groups: [[String]] = []
		var current: [String] = []
		for line in lines {
			let text = line.text.trimmingCharacters(in: .whitespaces)
			if text.isEmpty {
				if !current.isEmpty { groups.append(current) }
				current = []
			} else {
				current.append(text)
			}
		}
		if !current.isEmpty { groups.append(current) }
		return groups
	}

	public static func kind(of label: String) -> ChoiceMenu.Kind {
		let text = label.lowercased()
		for prefix in ["no", "deny", "reject", "cancel", "don't allow", "do not allow", "exit", "abort", "skip"]
		where text == prefix || text.hasPrefix(prefix + ",") || text.hasPrefix(prefix + " ") {
			return .deny
		}
		for prefix in ["yes", "allow", "approve", "proceed", "accept", "always allow", "trust", "continue", "run"]
		where text == prefix || text.hasPrefix(prefix + ",") || text.hasPrefix(prefix + " ") {
			return .approve
		}
		return .other
	}

	static func clip(_ text: String, limit: Int = maxText) -> String {
		text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
	}
}

