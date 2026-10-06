import XCTest

@testable import LinkHelperCore

/// §5.4 / §6: what leaves herdr and what the subscriber understands.
final class HerdrMappingTests: XCTestCase {
	func testAgentMappingDropsTerminalTokensAndSessions() {
		let mapped = HerdrClient.mapAgent([
			"pane_id": "w1:p1", "agent": "claude", "agent_status": "blocked", "cwd": "/a",
			"foreground_cwd": "/a/b",
			"terminal_id": "term-1", "tokens": ["secret": "x"], "agent_session": ["id": "s"], "focused": true,
		])
		XCTAssertEqual(mapped["id"] as? String, "w1:p1")
		XCTAssertEqual(mapped["status"] as? String, "blocked")
		XCTAssertEqual(mapped["cwd"] as? String, "/a/b")
		XCTAssertNil(mapped["tokens"])
		XCTAssertNil(mapped["terminal_id"])
		XCTAssertNil(mapped["agent_session"])
	}

	func testBothEventLineShapesAndUnderscoreNamesNormalise() {
		let envelope = HerdrSubscriber.parseEventLine(["event": "pane_created", "data": ["type": "pane_created"]])
		XCTAssertEqual(envelope?.0, "pane.created")
		let flat = HerdrSubscriber.parseEventLine(["type": "pane.agent_status_changed", "pane_id": "w1:p1"])
		XCTAssertEqual(flat?.0, "pane.agent_status_changed")
		XCTAssertNil(HerdrSubscriber.parseEventLine(["id": "1", "result": ["type": "pong"]]))
	}

	func testAgentIDsKeysAndNamesAreClosedAlphabets() {
		XCTAssertTrue(LinkAPI.isValidAgentID("w3:p1"))
		XCTAssertFalse(LinkAPI.isValidAgentID("w3 p1"))
		XCTAssertTrue(LinkAPI.isValidKey("ctrl+c"))
		XCTAssertFalse(LinkAPI.isValidKey("a b"))
		XCTAssertFalse(LinkAPI.isValidName("../x"))
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1%3Ap1/interrupt")?.name, "agents.interrupt")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents")?.name, "agents.start")
		XCTAssertNil(LinkAPI.match("DELETE", "/v1/agents/w1%3Ap1"))
	}
}
