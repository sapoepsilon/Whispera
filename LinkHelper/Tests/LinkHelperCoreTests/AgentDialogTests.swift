import Foundation
import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// `/v1/agents/{id}/dialog` over a model of Claude Code 2.1.314's MCP elicitation form (the
/// parser and key driver are tested against real frames in agent-tui-protocol).
final class AgentDialogTests: XCTestCase {
	/// A checkbox and a text field, drawn like the real form.
	final class FakeElicitation: AgentAskTerminal, @unchecked Sendable {
		let lock = NSLock()
		var checkbox: Bool?
		var note: String?
		var focus = 0
		var result: String?
		var sent: [[String]] = []
		var swallow: Set<String> = []
		var status = "blocked"
		/// A screen no parser reads, for the unparsed dismiss.
		var raw: String?

		func read() throws -> AskTerminalScreen {
			lock.lock()
			defer { lock.unlock() }
			if let raw { return AskTerminalScreen(text: raw) }
			let rule = String(repeating: "─", count: 80)
			if result != nil { return AskTerminalScreen(text: "⏺ Done.\n\(rule)\n❯ \n\(rule)\n  -- INSERT --") }
			let box = checkbox == true ? "☒" : checkbox == false ? "☐" : focus == 0 ? "☐" : "not set"
			let text = note.map { $0.isEmpty && focus == 1 ? "Type something…" : $0 } ?? (focus == 1 ? "Type something…" : "not set")
			let lines = [
				"⏺ Calling bambu-printer…", "", rule,
				"  MCP server “bambu-printer” requests your input", "",
				"  Clear reported hardware errors on PRINTER0000001? Inspect the printer first.", "",
				"  \(focus == 0 ? "❯" : " ") \(checkbox == nil ? "*" : "✔") I checked the printer and confirm this operation: \(box)", "",
				"  \(focus == 1 ? "❯" : " ") \(note == nil ? " " : "✔") Note: \(text)", "",
				focus == 2 ? "  ❯ Accept    Decline" : focus == 3 ? "    Accept  ❯ Decline" : "    Accept    Decline", "",
				"  Esc to cancel · ↑/↓ to navigate · Backspace to unset · Space to toggle",
			]
			return AskTerminalScreen(text: lines.joined(separator: "\n"))
		}

		func send(keys: [String]) throws {
			lock.lock()
			defer { lock.unlock() }
			sent.append(keys)
			for key in keys where !swallow.contains(key) { press(key) }
		}

		func type(_ text: String) throws {
			lock.lock()
			defer { lock.unlock() }
			sent.append(["type:" + text])
			if focus == 1 { note = (note ?? "") + text }
		}

		func press(_ key: String) {
			if raw != nil, key == "esc" { raw = "⏺ Interrupted.\n❯ \n"; status = "idle"; return }
			guard result == nil else { return }
			switch key {
			case "down": focus = min(3, focus + 1)
			case "up": focus = max(0, focus - 1)
			case "space" where focus == 0: checkbox = !(checkbox ?? false)
			case "ctrl+u" where focus == 1: note = ""
			case "esc": result = "cancel"
			case "enter":
				if focus == 3 { result = "decline" } else if focus == 2, checkbox != nil {
					result = "accept checkbox=\(checkbox!) note=\(note ?? "-")"
				} else { focus += 1 }
			default: break
			}
		}
	}

	func makeTracker(_ form: FakeElicitation) -> AskTracker {
		let permissions = PermissionTracker(
			reader: PermissionTracker.Reader(
				status: { _ in (form.status, [:]) }, screen: { _ in try form.read().text }, sendKeys: { _, _ in }),
			publish: { _, _ in }, push: AgentPermissionTests.RecordingPush(), devices: { [] }, lastDevice: { nil }, now: { 1000 })
		return AskTracker(
			reader: AskTracker.Reader(status: { _ in (form.status, [:]) }, terminal: { _ in form }),
			permissions: permissions, publish: { _, _ in }, push: AgentPermissionTests.RecordingPush(), devices: { [] },
			lastDevice: { nil }, now: { 1000 }, poll: 0.001, timeout: 0.1)
	}

	func testGetReadsTheFormAndDiscoversItsFields() throws {
		let form = FakeElicitation()
		let state = try makeTracker(form).dialog("w1:p1")
		let dialog = try XCTUnwrap(state["dialog"] as? [String: Any])
		XCTAssertEqual(dialog["kind"] as? String, "mcp_elicitation")
		XCTAssertEqual(dialog["server"] as? String, "bambu-printer")
		let json = try XCTUnwrap(state["form"] as? [String: Any])
		let fields = try XCTUnwrap(json["fields"] as? [[String: Any]])
		XCTAssertEqual(fields.map { $0["kind"] as? String }, ["boolean", "text"], "the note's kind is read by moving onto it")
		XCTAssertEqual(fields.first?["required"] as? Bool, true)
		XCTAssertEqual(form.focus, 0, "the cursor is put back")
		XCTAssertEqual(form.sent, [["down"], ["up"]])
		XCTAssertNotNil(ElicitationFormParser.parse(try form.read().text))
	}

	func testAcceptDeclineAndCancel() throws {
		let accepted = FakeElicitation()
		var tracker = makeTracker(accepted)
		var promptID = try XCTUnwrap(ElicitationFormParser.parse(try accepted.read().text)?.id)
		let answer = try tracker.answerDialog(
			"w1:p1", action: .accept([.init(field: 0, value: .bool(true)), .init(field: 1, value: .text("ok"))]), promptID: promptID)
		XCTAssertEqual(accepted.result, "accept checkbox=true note=ok")
		XCTAssertEqual(answer["action"] as? String, "accept")
		XCTAssertEqual(answer["prompt_id"] as? String, promptID)

		let declined = FakeElicitation()
		tracker = makeTracker(declined)
		promptID = try XCTUnwrap(ElicitationFormParser.parse(try declined.read().text)?.id)
		_ = try tracker.answerDialog("w1:p1", action: .decline, promptID: promptID)
		XCTAssertEqual(declined.result, "decline")

		let cancelled = FakeElicitation()
		_ = try makeTracker(cancelled).answerDialog("w1:p1", action: .cancel, promptID: nil)
		XCTAssertEqual(cancelled.result, "cancel")
		XCTAssertEqual(cancelled.sent, [["esc"]])
	}

	func testStaleFormAndMissingPromptIDSendNothing() throws {
		let form = FakeElicitation()
		let tracker = makeTracker(form)
		XCTAssertThrowsError(try tracker.answerDialog("w1:p1", action: .decline, promptID: "0000000000000000")) { error in
			XCTAssertEqual((error as? APIError)?.code, "dialog_changed")
		}
		XCTAssertThrowsError(try tracker.answerDialog("w1:p1", action: .decline, promptID: nil)) { error in
			XCTAssertEqual((error as? APIError)?.code, "bad_request")
		}
		XCTAssertTrue(form.sent.isEmpty)
	}

	func testStopSaysWhere() throws {
		let form = FakeElicitation()
		form.swallow = ["space"]
		let promptID = try XCTUnwrap(ElicitationFormParser.parse(try form.read().text)?.id)
		XCTAssertThrowsError(
			try makeTracker(form).answerDialog("w1:p1", action: .accept([.init(field: 0, value: .bool(true))]), promptID: promptID)
		) { error in
			let api = error as? APIError
			XCTAssertEqual(api?.code, "dialog_stuck")
			XCTAssertEqual(api?.extra["stopped_at"] as? String, "field 1 of 2 (I checked the printer and confirm this operation)")
			XCTAssertTrue(api?.message.hasPrefix("Your Mac stopped at field 1 of 2") == true)
		}
		XCTAssertNil(form.result)
		XCTAssertFalse(form.sent.contains(["enter"]))
	}

	func testDismissABlockedScreenNoParserReads() throws {
		let form = FakeElicitation()
		form.raw = "⏺ Something odd\n\n  Press any key\n"
		XCTAssertNil(try makeTracker(form).dialog("w1:p1")["dialog"] as? [String: Any])
		let answer = try makeTracker(form).answerDialog("w1:p1", action: .cancel, promptID: nil)
		XCTAssertEqual(answer["action"] as? String, "cancel")
		XCTAssertEqual(form.sent, [["esc"]])

		let idle = FakeElicitation()
		idle.raw = "❯ \n"
		idle.status = "idle"
		XCTAssertThrowsError(try makeTracker(idle).answerDialog("w1:p1", action: .cancel, promptID: nil)) { error in
			XCTAssertEqual((error as? APIError)?.code, "not_blocked")
		}
		XCTAssertTrue(idle.sent.isEmpty)
	}

	func testParseDialogAnswer() throws {
		let id = "0123456789abcdef"
		let accept = try LinkAPI.parseDialogAnswer([
			"action": "accept", "prompt_id": id, "values": [["field": 0, "value": true], ["field": 1, "value": "PETG"]],
		])
		XCTAssertEqual(accept.action, .accept([.init(field: 0, value: .bool(true)), .init(field: 1, value: .text("PETG"))]))
		XCTAssertEqual(accept.promptID, id)
		XCTAssertEqual(try LinkAPI.parseDialogAnswer(["action": "cancel"]).action, .cancel)
		XCTAssertNil(try LinkAPI.parseDialogAnswer(["action": "cancel"]).promptID)
		for bad: [String: Any] in [
			["action": "submit"], ["action": "accept", "prompt_id": "xyz"],
			["action": "accept", "values": [["field": 0, "value": 1]]],
			["action": "accept", "values": [["field": 0, "value": "two\nlines"]]],
			["action": "accept", "values": [["value": true]]],
		] {
			XCTAssertThrowsError(try LinkAPI.parseDialogAnswer(bad), "\(bad)")
		}
	}

	func testRoutes() {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1%3Ap1/dialog")?.name, "agents.dialog")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1%3Ap1/dialog")?.name, "agents.dialog.answer")
	}
}
