// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import CryptoKit
import Foundation

/// An MCP server's elicitation form (`elicitation/create`) as Claude Code draws it, read field
/// by field so the phone can show it natively and answer it.
///
/// Claude Code 2.1.314 draws one row per field, then the buttons:
///
///     MCP server “x” requests your input
///
///     Configure the test print job.
///
///     ❯ * Bed is clear: ☐            cursor, marker (* required and unset, ✔ set, ⚠ invalid)
///           Tick to confirm          the field's description, then any validation error
///
///         Job note: not set          an unfocused unset field does not say its kind
///
///         Material: ▸ not set        a focused enum (→ expands it, ← collapses)
///
///       Accept    Decline            "❯ Accept" or "Accept  ❯ Decline" with the cursor on one
///
///     Esc to cancel · ↑/↓ to navigate · Backspace to unset · Space to toggle
///
/// A focused field shows its kind: ☐/☒ a boolean, "Type something…" or its text a text or
/// number field, "▸ value" an enum. An unfocused field that is set shows ☐/☒ (boolean) or its
/// value; one that is unset shows "not set". `ElicitationDriver.discover` visits the fields
/// whose kind the screen does not show.
public struct ElicitationForm: Codable, Equatable, Sendable {
	public enum Value: Codable, Equatable, Sendable {
		case unset
		case bool(Bool)
		/// A text, number or enum field's value as drawn.
		case text(String)

		public init(from decoder: Decoder) throws {
			let container = try decoder.singleValueContainer()
			if container.decodeNil() {
				self = .unset
			} else if let value = try? container.decode(Bool.self) {
				self = .bool(value)
			} else {
				self = .text(try container.decode(String.self))
			}
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.singleValueContainer()
			switch self {
			case .unset: try container.encodeNil()
			case .bool(let value): try container.encode(value)
			case .text(let value): try container.encode(value)
			}
		}
	}

	public struct Field: Codable, Equatable, Sendable {
		public enum Kind: String, Codable, Sendable {
			case boolean
			/// Text or a number: typed.
			case text
			/// An enum: one of `options`.
			case choice
			/// Unfocused and unset: the screen does not say.
			case unknown
		}

		public var label: String
		public var kind: Kind
		/// Marked `*` while unset. Only known once seen unset.
		public var required: Bool
		public var value: Value
		/// An enum's options, once the list was seen expanded.
		public var options: [String]
		public var description: String?
		/// Claude Code's validation message under the field ("This field is required").
		public var error: String?

		public init(
			label: String, kind: Kind, required: Bool = false, value: Value = .unset, options: [String] = [],
			description: String? = nil, error: String? = nil
		) {
			self.label = label
			self.kind = kind
			self.required = required
			self.value = value
			self.options = options
			self.description = description
			self.error = error
		}
	}

	/// Where the cursor is: a field, or one of the buttons.
	public enum Focus: Codable, Equatable, Sendable {
		case field(Int)
		case accept
		case decline

		/// Row order for ↑/↓: the fields, then Accept, then Decline.
		func position(fields: Int) -> Int {
			switch self {
			case .field(let index): return index
			case .accept: return fields
			case .decline: return fields + 1
			}
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let index = try? container.decode(Int.self) {
				self = .field(index)
			} else {
				switch try container.decode(String.self) {
				case "accept": self = .accept
				case "decline": self = .decline
				default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown focus")
				}
			}
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.singleValueContainer()
			switch self {
			case .field(let index): try container.encode(index)
			case .accept: try container.encode("accept")
			case .decline: try container.encode("decline")
			}
		}
	}

	/// A digest of the server, message and field labels: the same form while values change.
	public var id: String
	public var server: String?
	public var message: String
	public var fields: [Field]
	public var focus: Focus?
	/// The enum field whose option list is open, and the option under its cursor.
	public var expanded: Int?
	public var optionCursor: Int?

	enum CodingKeys: String, CodingKey {
		case id = "prompt_id"
		case server, message, fields, focus, expanded
		case optionCursor = "option_cursor"
	}

	public init(server: String?, message: String, fields: [Field], focus: Focus?, expanded: Int? = nil, optionCursor: Int? = nil) {
		self.server = server
		self.message = message
		self.fields = fields
		self.focus = focus
		self.expanded = expanded
		self.optionCursor = optionCursor
		id = Self.fingerprint(server: server, message: message, labels: fields.map(\.label))
	}

	static func fingerprint(server: String?, message: String, labels: [String]) -> String {
		let parts = ["elicitation", server ?? "", message] + labels
		let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))
		return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	/// Every field's kind is known and every enum's options were read.
	public var complete: Bool {
		fields.allSatisfy { $0.kind != .unknown && ($0.kind != .choice || !$0.options.isEmpty) }
	}

	/// Folds in what a later read of the same form showed (a field's kind, an enum's options,
	/// `*`); values come from the later read. False for a different form.
	public mutating func merge(_ later: ElicitationForm) -> Bool {
		guard later.id == id else { return false }
		var fields = later.fields
		for index in fields.indices {
			let known = self.fields[index]
			if fields[index].kind == .unknown { fields[index].kind = known.kind }
			if fields[index].options.isEmpty { fields[index].options = known.options }
			fields[index].required = fields[index].required || known.required
			if fields[index].description == nil { fields[index].description = known.description }
		}
		self.fields = fields
		focus = later.focus
		expanded = later.expanded
		optionCursor = later.optionCursor
		return true
	}

	public var jsonObject: [String: Any] {
		guard let data = try? JSONEncoder().encode(self),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return [:] }
		return object
	}
}

public enum ElicitationFormParser {
	static let notSet = "not set"
	static let placeholder = "Type something\u{2026}"
	static let unchecked: Character = "\u{2610}"
	static let checked: Character = "\u{2612}"
	static let markers: Set<Character> = ["\u{2714}", "*", "\u{26A0}", " "]
	static let radios: Set<Character> = ["\u{25EF}", "\u{25CB}"]
	static let selectedRadios: Set<Character> = ["\u{25C9}", "\u{25CF}", "\u{25CE}"]

	/// The elicitation form at the bottom of `screen`, or nil when the screen shows none.
	public static func parse(_ screen: String) -> ElicitationForm? {
		guard let dialog = BlockedDialogParser.parse(screen), dialog.kind == .mcpElicitation else { return nil }
		let raw = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
			.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
		guard
			let header = raw.lastIndex(where: { $0.range(of: BlockedDialogParser.elicitationHeader, options: .regularExpression) != nil }),
			let footer = raw[header...].lastIndex(where: BlockedDialogParser.isKeyFooter)
		else { return nil }
		let base = raw[header].prefix { $0 == " " }.count
		let body = raw[(header + 1)..<footer].map { line -> String in
			String(line.dropFirst(min(base, line.prefix { $0 == " " }.count)))
		}

		var message: [String] = []
		var fields: [ElicitationForm.Field] = []
		var focus: ElicitationForm.Focus?
		var expanded: Int?
		var optionCursor: Int?
		var sawButtons = false
		/// Continuation lines (description, error, options) of the last field.
		var extra: [String] = []
		var lastMarker: Character = " "

		func closeField() {
			guard !fields.isEmpty else { return }
			let index = fields.count - 1
			var notes = extra
			if expanded == index {
				for line in extra {
					var text = Substring(line.trimmingCharacters(in: .whitespaces))
					var underCursor = false
					if let first = text.first, ChoiceMenuParser.cursors.contains(first) {
						underCursor = true
						text = text.dropFirst().drop { $0 == " " }
					}
					guard let radio = text.first, radios.contains(radio) || selectedRadios.contains(radio) else { continue }
					let label = text.dropFirst().trimmingCharacters(in: .whitespaces)
					if underCursor { optionCursor = fields[index].options.count }
					if selectedRadios.contains(radio) { fields[index].value = .text(label) }
					fields[index].options.append(label)
					notes.removeAll { $0 == line }
				}
			}
			if lastMarker == "\u{26A0}", let last = notes.popLast() { fields[index].error = last }
			if !notes.isEmpty { fields[index].description = notes.joined(separator: " ") }
			extra = []
		}

		for line in body {
			if line.isEmpty { continue }
			if BlockedDialogParser.isAcceptDeclineRow(line) {
				closeField()
				sawButtons = true
				let text = line.trimmingCharacters(in: .whitespaces)
				if let first = text.first, ChoiceMenuParser.cursors.contains(first) {
					focus = .accept
				} else if let decline = text.range(of: "Decline"),
					text[..<decline.lowerBound].trimmingCharacters(in: .whitespaces).last.map(ChoiceMenuParser.cursors.contains) == true
				{
					focus = .decline
				}
				continue
			}
			if sawButtons { continue }
			if let row = fieldRow(line) {
				closeField()
				let index = fields.count
				if row.focused { focus = .field(index) }
				lastMarker = row.marker
				var field = ElicitationForm.Field(label: row.label, kind: .unknown, required: row.marker == "*")
				let value = row.value
				if value.last == checked || value.last == unchecked, value.count == 1 {
					field.kind = .boolean
					field.value = value.last == checked ? .bool(true) : (row.marker == "\u{2714}" ? .bool(false) : .unset)
				} else if value == "\u{25BE}" {
					field.kind = .choice
					expanded = index
				} else if value.hasPrefix("\u{25B8}") {
					field.kind = .choice
					let shown = value.dropFirst().trimmingCharacters(in: .whitespaces)
					field.value = shown == notSet ? .unset : .text(shown)
				} else if value == placeholder {
					field.kind = .text
					field.value = row.marker == "\u{2714}" ? .text("") : .unset
				} else if value == notSet {
					field.value = .unset
				} else {
					// Focused plain text is a text field (an enum shows ▸, a boolean ☐/☒).
					if row.focused { field.kind = .text }
					field.value = .text(value)
				}
				fields.append(field)
				continue
			}
			if fields.isEmpty {
				message.append(line.trimmingCharacters(in: .whitespaces))
			} else if line.prefix(while: { $0 == " " }).count >= 4 {
				extra.append(line.trimmingCharacters(in: .whitespaces))
			}
		}
		closeField()
		guard sawButtons, !fields.isEmpty else { return nil }
		return ElicitationForm(
			server: dialog.server, message: message.joined(separator: "\n"), fields: fields, focus: focus, expanded: expanded,
			optionCursor: optionCursor)
	}

	struct Row {
		var focused: Bool
		var marker: Character
		var label: String
		var value: String
	}

	/// "❯ ✔ Label: value": cursor column, marker column, then the label from column 4.
	static func fieldRow(_ line: String) -> Row? {
		let chars = Array(line)
		guard chars.count >= 6, chars[0] == " " || ChoiceMenuParser.cursors.contains(chars[0]), chars[1] == " ",
			markers.contains(chars[2]), chars[3] == " ", chars[4] != " "
		else { return nil }
		let rest = String(chars[4...])
		let label: Substring
		let value: Substring
		let endings = [": \(unchecked)", ": \(checked)", ": \u{25BE}", ": \(notSet)", ": \(placeholder)"]
		if let ending = endings.first(where: rest.hasSuffix) {
			label = rest.dropLast(ending.count)
			value = Substring(ending.dropFirst(2))
		} else if let range = rest.range(of: ": \u{25B8} ") {
			label = rest[..<range.lowerBound]
			value = rest[rest.index(range.lowerBound, offsetBy: 2)...]
		} else if rest.hasSuffix(":") {
			label = rest.dropLast()
			value = ""
		} else if let range = rest.range(of: ": ") {
			label = rest[..<range.lowerBound]
			value = rest[range.upperBound...]
		} else {
			return nil
		}
		let name = label.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty else { return nil }
		return Row(focused: chars[0] != " ", marker: chars[2], label: name, value: String(value))
	}
}
