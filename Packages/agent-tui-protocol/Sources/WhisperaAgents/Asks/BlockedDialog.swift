// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ismatulla Mansurov
import Foundation

/// A dialog an agent is blocked on that neither `ChoiceMenuParser` nor `AgentAskParser`
/// can answer, read off the screen so the phone shows the dialog itself instead of the
/// transcript above it.
///
/// The case it was made for: an MCP server's elicitation (`elicitation/create`), which
/// Claude Code draws as "MCP server “x” requests your input" with form fields and an
/// Accept/Decline row, and which a background subagent's tool call can raise while the
/// main agent only waits on that subagent. herdr reports the pane `blocked` (rule
/// `mcp_elicitation_prompt`), and it is: the subagent's tool call does not return until
/// someone answers in the terminal.
public struct BlockedDialog: Equatable, Sendable {
	public enum Kind: String, Sendable, Codable {
		/// An MCP server's request for input (`elicitation/create`).
		case mcpElicitation = "mcp_elicitation"
		/// Any other dialog with a key footer that no parser reads.
		case other
	}

	public var kind: Kind
	/// The dialog's heading ("MCP server “bambu-printer” requests your input").
	public var title: String?
	/// The MCP server that asks, for an elicitation.
	public var server: String?
	/// The dialog's lines between its heading and its key footer, common indent removed.
	public var lines: [String]
	/// The key footer ("Esc to cancel · ↑/↓ to navigate · …").
	public var footer: String?

	public var text: String { lines.joined(separator: "\n") }
}

public enum BlockedDialogParser {
	/// "MCP server “x” requests your input", as herdr's `mcp_elicitation_prompt` rule reads it.
	static let elicitationHeader = #"^\s*MCP server ["\x{201C}](.+)["\x{201D}] requests your input\s*$"#
	static let maxLines = 16

	/// The dialog below the screen's last full-width rule, when that region ends in a key
	/// footer a dialog draws. Nil for the idle input box and its mode line, and for a
	/// screen without a rule. A menu `ChoiceMenuParser` reads parses here too (callers try it
	/// first); a question form `AgentAskParser` reads never does.
	public static func parse(_ screen: String) -> BlockedDialog? {
		// A question form is answered by its own card. Offered as a dialog, its Dismiss (Esc)
		// would cancel the agent's AskUserQuestion: never.
		guard AgentAskParser.screen(text: screen) == nil else { return nil }
		let raw = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
		guard let rule = raw.lastIndex(where: ChoiceMenuParser.isDialogTop) else { return nil }
		var region = raw[(rule + 1)...].map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
		while region.last?.isEmpty == true { region.removeLast() }
		while region.first?.isEmpty == true { region.removeFirst() }
		guard let footerIndex = region.lastIndex(where: isKeyFooter) else { return nil }
		let footer = region[footerIndex].trimmingCharacters(in: .whitespaces)
		var body = Array(region[..<footerIndex])
		while body.last?.isEmpty == true { body.removeLast() }
		guard !body.isEmpty else { return nil }

		var kind = BlockedDialog.Kind.other
		var title: String?
		var server: String?
		if let headerIndex = body.firstIndex(where: { $0.range(of: elicitationHeader, options: .regularExpression) != nil }),
			body[(headerIndex + 1)...].contains(where: isAcceptDeclineRow)
		{
			kind = .mcpElicitation
			let header = body[headerIndex].trimmingCharacters(in: .whitespaces)
			title = header
			server = serverName(header)
			body = Array(body[(headerIndex + 1)...])
		}
		let lines = ChoiceMenuParser.trimCommonIndent(body)
		guard !lines.isEmpty else { return nil }
		return BlockedDialog(kind: kind, title: title, server: server, lines: Array(lines.prefix(maxLines)), footer: footer)
	}

	/// A dialog's own footer: it names the keys that cancel or confirm it. The input box's
	/// mode line ("shift+tab to cycle", "? for shortcuts") is not one.
	static func isKeyFooter(_ line: String) -> Bool {
		let text = line.lowercased()
		return ["esc to cancel", "esc to exit", "enter to confirm", "enter to select", "to navigate"].contains(where: text.contains)
	}

	/// The elicitation's buttons: "Accept    Decline", with the cursor on either.
	static func isAcceptDeclineRow(_ line: String) -> Bool {
		var text = Substring(line.trimmingCharacters(in: .whitespaces))
		if let first = text.first, ChoiceMenuParser.cursors.contains(first) { text = text.dropFirst() }
		let words = text.split(whereSeparator: { $0 == " " || ChoiceMenuParser.cursors.contains($0) })
		return words.first.map { $0 == "Accept" || $0 == "Decline" } == true && words.contains("Decline")
	}

	static func serverName(_ header: String) -> String? {
		guard let open = header.firstIndex(where: { $0 == "\u{201C}" || $0 == "\"" }) else { return nil }
		let rest = header[header.index(after: open)...]
		guard let close = rest.firstIndex(where: { $0 == "\u{201D}" || $0 == "\"" }) else { return nil }
		let name = rest[..<close].trimmingCharacters(in: .whitespaces)
		return name.isEmpty ? nil : name
	}
}
