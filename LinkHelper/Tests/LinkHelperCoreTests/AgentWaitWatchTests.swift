import XCTest

@testable import LinkHelperCore

/// An agent herdr calls idle while its session log shows a turn waiting on the owner (Claude
/// Code's view scrolled up over a permission dialog).
final class AgentWaitWatchTests: XCTestCase {
	var waiting: Set<String> = []
	var herdrStatus = "idle"
	var screen = ""
	var scrolls: [String] = []
	var published: [(String, [String: Any])] = []

	private func makeWatch() -> AgentWaitWatch {
		AgentWaitWatch(
			hooks: AgentWaitWatch.Hooks(
				waiting: { [unowned self] in waiting.contains($0) }, bind: { _ in },
				status: { [unowned self] _ in (herdrStatus, ["agent": "claude", "name": "cq"]) },
				screen: { [unowned self] _ in screen },
				scrollToBottom: { [unowned self] in scrolls.append($0) }),
			publish: { [unowned self] in published.append(($0, $1)) })
	}

	func testQuietAgentWithOpenTurnIsBlockedAndScrolledDown() {
		let watch = makeWatch()
		watch.observe("agent.status", ["id": "w1:p1", "status": "idle"])
		watch.tick()
		XCTAssertTrue(published.isEmpty, "a closed turn is idle")

		waiting = ["w1:p1"]
		screen = "  row 300 is fine\n\n✻ Baked for 9s · done 8:42 AM                 1 new message (click) ↓\n"
		watch.tick()
		XCTAssertEqual(scrolls, ["w1:p1"])
		XCTAssertEqual(published.last?.0, "agent.status")
		XCTAssertEqual(published.last?.1["status"] as? String, "blocked")
		XCTAssertEqual(published.last?.1["source"] as? String, AgentWaitWatch.source)
		XCTAssertEqual(watch.effective("w1:p1", "idle"), "blocked")
		XCTAssertEqual(watch.annotate(["id": "w1:p1", "status": "idle"])["status"] as? String, "blocked")

		// Its own event is not herdr's: it changes nothing.
		watch.observe("agent.status", published.last!.1)
		XCTAssertTrue(watch.isWaiting("w1:p1"))

		// Answered: herdr sees it work again.
		watch.observe("agent.status", ["id": "w1:p1", "status": "working"])
		XCTAssertEqual(watch.effective("w1:p1", "idle"), "idle")
	}

	func testNoScrollWithoutTheMarkerAndNothingForHerdrBlocked() {
		let watch = makeWatch()
		waiting = ["w1:p1"]
		screen = "❯ 1. Yes\n  2. No\n"
		herdrStatus = "blocked"
		watch.consider("w1:p1", status: "idle")
		watch.tick()
		XCTAssertTrue(scrolls.isEmpty, "keys or mouse go only to a view that hides new output")
		XCTAssertTrue(published.isEmpty, "herdr already reports the dialog")
		XCTAssertEqual(watch.effective("w1:p1", "blocked"), "blocked")
	}

	func testWaitEndsWhenTheTurnCloses() {
		let watch = makeWatch()
		waiting = ["w1:p1"]
		watch.consider("w1:p1", status: "done")
		watch.tick()
		XCTAssertTrue(watch.isWaiting("w1:p1"))
		waiting = []
		watch.tick()
		XCTAssertFalse(watch.isWaiting("w1:p1"))
		XCTAssertEqual(published.last?.1["status"] as? String, "idle")
	}

	func testMarkerSpellings() {
		XCTAssertTrue(AgentWaitWatch.hidesNewOutput("⏺ Update(calc.py)        Jump to bottom (click) ↓"))
		XCTAssertTrue(AgentWaitWatch.hidesNewOutput("x\n   3 new messages ↓\n"))
		XCTAssertFalse(AgentWaitWatch.hidesNewOutput("❯ \n  ? for shortcuts"))
	}

	func testBridgeSendsOnlyWheelDown() throws {
		let client = HerdrClient(socketPath: "/nonexistent/herdr.sock")
		XCTAssertThrowsError(try client.call("pane.send_text", ["pane_id": "w1:p1", "text": "rm -rf ~\r"])) { error in
			XCTAssertEqual((error as? APIError)?.status, 500)
		}
		XCTAssertThrowsError(try client.call("pane.send_text", ["pane_id": "w1:p1", "text": HerdrClient.wheelDown + "y"]))
		// Only the socket is missing: the text itself is allowed.
		XCTAssertThrowsError(try client.scrollToBottom("w1:p1")) { error in
			XCTAssertEqual((error as? APIError)?.code, "herdr_unavailable")
		}
	}
}
