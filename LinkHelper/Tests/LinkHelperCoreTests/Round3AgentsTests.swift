import Foundation
import XCTest

@testable import LinkHelperCore

/// Round-3 QA: a just-started agent's first prompt (#2, #7) and dialogs caught mid-redraw (#3).
final class Round3AgentsTests: XCTestCase {
	// MARK: Not ready

	func testNotReadyIsAConflictThatSentNothing() {
		let error = HerdrClient.mapError("agent_not_ready", "agent w1:p1 is not an active named agent")
		XCTAssertEqual(error.status, 409)
		XCTAssertEqual(error.code, "agent_not_ready")
		XCTAssertEqual(error.extra["herdr_code"] as? String, "agent_not_ready")
		XCTAssertTrue(AgentSubmissions.nothingSent.contains("agent_not_ready"))
	}

	func testNotReadyDropsTheReceiptSoTheRetryIsAFreshDelivery() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let submissions = AgentSubmissions(stateDirectory: dir)
		let id = UUID().uuidString.lowercased()
		XCTAssertThrowsError(
			try submissions.submit(id, device: "dev1", agent: "w1:p1", text: "hi", images: [], prepare: { $0 }) { _ in
				throw HerdrClient.mapError("agent_not_ready", nil)
			}
		) { XCTAssertEqual(($0 as? APIError)?.code, "agent_not_ready") }
		var delivered: [String] = []
		let answer = try submissions.submit(id, device: "dev1", agent: "w1:p1", text: "hi", images: [], prepare: { $0 }) {
			delivered.append($0)
			return ["agent": ["id": "w1:p1"]]
		}
		XCTAssertEqual(delivered, ["hi"])
		XCTAssertNotNil(answer["agent"])
	}

	func testAnUnknownFailureStillKeepsTheReceipt() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let submissions = AgentSubmissions(stateDirectory: dir)
		let id = UUID().uuidString.lowercased()
		for _ in 0..<2 {
			XCTAssertThrowsError(
				try submissions.submit(id, device: "dev1", agent: "w1:p1", text: "hi", images: [], prepare: { $0 }) { _ in
					throw APIError(504, "herdr_timeout", "slow")
				}
			) { XCTAssertEqual(($0 as? APIError)?.code, "delivery_unknown") }
		}
	}

	// MARK: Startup status

	final class Pane: @unchecked Sendable {
		let lock = NSLock()
		var info: [String: Any] = ["agent_status": "working", "launch_pending": true, "agent": "codex"]
		var screen = ""
		var open: Bool?
		func set(_ change: (Pane) -> Void) { lock.lock(); change(self); lock.unlock() }
		var hooks: AgentStartup.Hooks {
			AgentStartup.Hooks(
				raw: { [self] _ in lock.lock(); defer { lock.unlock() }; return info },
				screen: { [self] _ in lock.lock(); defer { lock.unlock() }; return screen },
				turnOpen: { [self] _ in lock.lock(); defer { lock.unlock() }; return open })
		}
	}

	static let codexIdle = """
		╭───────────────────────────────╮
		│ >_ OpenAI Codex (v0.164.0)    │
		╰───────────────────────────────╯

		› Ask Codex to do anything

		  GPT-6-Luna low · /private/tmp/sb
		"""
	static let codexSplash = """
		╭───────────────────────────────╮
		│ >_ OpenAI Codex (v0.164.0)    │
		╰───────────────────────────────╯
		"""

	func testIdlePromptOnScreen() {
		XCTAssertTrue(AgentStartup.idlePromptVisible(Self.codexIdle))
		XCTAssertFalse(AgentStartup.idlePromptVisible(Self.codexSplash))
		XCTAssertFalse(AgentStartup.idlePromptVisible(Self.codexIdle + "\n• Working (3s • esc to interrupt)"))
		XCTAssertTrue(AgentStartup.idlePromptVisible("────\n❯ \n────\n  -- INSERT -- ⏸ manual mode on"))
	}

	func testLaunchingAgentAtItsIdlePromptReadsIdle() {
		let pane = Pane()
		let events = AgentPermissionTests.Events()
		let startup = AgentStartup(hooks: pane.hooks, publish: { events.add($0, $1) })
		pane.set { $0.screen = Self.codexSplash }
		let splash = startup.annotate(["id": "w1:p1", "status": "working", "launch_pending": true])
		XCTAssertEqual(splash["status"] as? String, "working")

		// The prompt is drawn while herdr still says working: phones see idle, through an event.
		pane.set { $0.screen = Self.codexIdle }
		startup.tick(now: Date().addingTimeInterval(2))
		XCTAssertEqual(events.list.last?.1["status"] as? String, "idle")
		XCTAssertEqual(events.list.last?.1["source"] as? String, AgentStartup.source)
		let ready = startup.annotate(["id": "w1:p1", "status": "working", "launch_pending": true])
		XCTAssertEqual(ready["status"] as? String, "idle")

		// A turn open in the log is real work; a finished launch is herdr's own status.
		pane.set { $0.open = true }
		Thread.sleep(forTimeInterval: 1.05)
		XCTAssertEqual(startup.annotate(["id": "w1:p1", "status": "working", "launch_pending": true])["status"] as? String, "working")
		XCTAssertEqual(startup.annotate(["id": "w1:p1", "status": "working"])["status"] as? String, "working")
		XCTAssertEqual(startup.annotate(["id": "tmux:x", "status": "working", "launch_pending": true])["status"] as? String, "working")
	}

	func testHerdrWorkingEventIsCorrectedWhileLaunching() {
		let pane = Pane()
		pane.set { $0.screen = Self.codexIdle }
		let startup = AgentStartup(hooks: pane.hooks, publish: { _, _ in })
		let corrected = startup.correct("agent.status", ["id": "w1:p1", "status": "working"])
		XCTAssertEqual(corrected["status"] as? String, "idle")
		pane.set { $0.info["launch_pending"] = nil }
		XCTAssertEqual(startup.correct("agent.status", ["id": "w1:p1", "status": "working"])["status"] as? String, "working")
	}

	func testPromptWaitsForTheLaunchToEnd() {
		let pane = Pane()
		let startup = AgentStartup(hooks: pane.hooks, publish: { _, _ in })
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { pane.set { $0.info["launch_pending"] = nil } }
		let started = Date()
		startup.waitUntilReady("w1:p1", timeout: 5, poll: 0.05)
		let waited = Date().timeIntervalSince(started)
		XCTAssertGreaterThan(waited, 0.25)
		XCTAssertLessThan(waited, 2)

		// Bounded: still launching after the timeout, the prompt goes and herdr answers not ready.
		pane.set { $0.info["launch_pending"] = true }
		let bounded = Date()
		startup.waitUntilReady("w1:p1", timeout: 0.2, poll: 0.05)
		XCTAssertLessThan(Date().timeIntervalSince(bounded), 1)
	}

	// MARK: Debounce

	func testADialogSeenOnlyOnceIsNotPublished() throws {
		let agent = AgentPermissionTests.FakeAgent()
		let push = AgentPermissionTests.RecordingPush()
		let events = AgentPermissionTests.Events()
		let tracker = PermissionTracker(
			reader: PermissionTracker.Reader(
				status: { _ in ("blocked", [:]) },
				screen: { id in
					// First read: a transient menu; every later read: the real dialog.
					defer { agent.lock.lock(); agent.sent.append([]); agent.lock.unlock() }
					agent.lock.lock(); let first = agent.sent.isEmpty; agent.lock.unlock()
					return first ? AgentPermissionTests.claudeTrust : AgentPermissionTests.claudeBash
				}, sendKeys: { _, _ in }),
			publish: { events.add($0, $1) }, push: push, devices: { [] }, lastDevice: { nil }, now: { 1000 }, settle: 0.05)
		let current = try tracker.current("w1:p1")
		let permission = try XCTUnwrap(current["permission"] as? [String: Any])
		XCTAssertEqual(permission["question"] as? String, "Do you want to proceed?")
		XCTAssertEqual(push.pushed.count, 1)
		XCTAssertEqual(events.names.filter { $0 == "agent.permission" }.count, 1)
	}
}
