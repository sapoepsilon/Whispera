import XCTest

@testable import LinkHelperCore

/// Roadmap R1: a blocked agent's dialog parsed off herdr's detection text, and an option
/// turned into keys on the Mac. The Claude Code screens are herdr 0.9.1 captures
/// (`agent read --source detection`) of Claude Code 2.1 in a throwaway session.
final class AgentPermissionTests: XCTestCase {
	static let rule = String(repeating: "─", count: 119)
	static let dashes = String(repeating: "╌", count: 119)

	static let claudeBash = """
		 ▐▛███▛█   Claude Code v2.1.312
		▝▜██████▀  Opus 5.5 · Claude Max

		❯ Use the Bash tool to run exactly this command: curl -sI https://example.com -o /tmp/x/head.txt . Do
		  not do anything else.

		  Fetching example.com headers into a file
		  ⎿  $ curl -sI https://example.com -o /tmp/x/head.txt

		\(rule)
		 Bash command
		 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
		 Fetch example.com headers into a file
		\(dashes)
		 curl -sI https://example.com -o /tmp/x/head.txt
		\(dashes)
		 This command requires approval

		 Do you want to proceed?
		 ❯ 1. Yes
		   2. Yes, and don’t ask again for: curl *
		   3. Yes, and switch to auto mode · auto mode handles these prompts for you
		   4. No

		 Esc to cancel · Tab to amend
		"""

	/// No blank line between the command and the question (Claude Code 2.1, `touch`).
	static let claudeTouch = """
		\(rule)
		 Bash command
		 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
		 Create an empty marker file
		\(dashes)
		 touch /tmp/herdr-r1/sandbox/approved-from-phone.txt
		\(dashes)
		 Do you want to proceed?
		 ❯ 1. Yes
		   2. Yes, and always allow access to /tmp/herdr-r1/sandbox from this project
		   3. Yes, and switch to auto mode · auto mode handles these prompts for you
		   4. No

		 Esc to cancel · Tab to amend
		"""

	static let claudeTrust = """
		> claude

		\(rule)
		 Accessing workspace:

		 /private/tmp/herdr-r1/sandbox

		 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
		 project, or work from your team). If not, take a moment to review what's in this folder first.

		 Claude Code'll be able to read, edit, and execute files here.

		 Security guide

		 ❯ No, exit
		   Yes, I trust this folder

		 Enter to confirm · Esc to cancel
		"""

	/// Codex's folder-trust dialog, captured the same way (no rule above it).
	static let codexTrust = """

		  Folder access
		  /private/tmp/herdr-r1/sandbox

		  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings
		  can run code automatically, even without a model request. Continue only if you trust these files. Your trust
		  decision will be saved.

		› 1. Trust and continue
		  2. Back to Agent Command Center

		  enter continue · esc back
		"""

	static let codexCommand = """
		› run the tests

		• Running the test suite.

		  Would you like to run the following command?

		  $ swift test --filter AgentPermissionTests

		  1. Yes, proceed (y)
		› 2. Yes, and don't ask again for this command (a)
		  3. No, and tell Codex what to do differently (esc)

		  Press enter to confirm or esc to cancel
		"""

	static let boxed = """
		╭──────────────────────────────────────────────╮
		│ Edit file                                    │
		│ Sources/App.swift                            │
		│                                              │
		│ Do you want to make this edit to App.swift?  │
		│ ❯ 1. Yes                                     │
		│   2. Yes, allow all edits during this session│
		│   3. No, and tell Claude what to do          │
		│      differently (esc)                       │
		╰──────────────────────────────────────────────╯
		"""

	func testClaudeBashPermission() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.claudeBash))
		XCTAssertEqual(prompt.title, "Bash command")
		XCTAssertEqual(prompt.question, "Do you want to proceed?")
		XCTAssertEqual(
			prompt.detail,
			"curl -sI https://example.com -o /tmp/x/head.txt\nFetch example.com headers into a file")
		XCTAssertEqual(prompt.options.map(\.label), [
			"Yes", "Yes, and don’t ask again for: curl *",
			"Yes, and switch to auto mode · auto mode handles these prompts for you", "No",
		])
		XCTAssertEqual(prompt.options.map(\.kind), [.approve, .approve, .approve, .deny])
		XCTAssertEqual(prompt.options.map(\.id), ["1", "2", "3", "4"])
		XCTAssertEqual(prompt.selectedIndex, 0)
		XCTAssertEqual(prompt.cancelKey, "esc")
		XCTAssertEqual(prompt.id.count, 16)
	}

	func testClaudeQuestionInTheSameParagraphAsTheCommand() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.claudeTouch))
		XCTAssertEqual(prompt.title, "Bash command")
		XCTAssertEqual(prompt.question, "Do you want to proceed?")
		XCTAssertEqual(
			prompt.detail, "touch /tmp/herdr-r1/sandbox/approved-from-phone.txt\nCreate an empty marker file")
		XCTAssertEqual(prompt.purpose, .permission)
		XCTAssertEqual(prompt.summary, "Create an empty marker file")
		XCTAssertEqual(prompt.command, "touch /tmp/herdr-r1/sandbox/approved-from-phone.txt")
		XCTAssertEqual(prompt.options.count, 4)
		XCTAssertEqual(prompt.keys(for: "1"), ["enter"])
	}

	func testClaudeTrustDialogWithoutNumbers() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.claudeTrust))
		XCTAssertEqual(prompt.title, "Accessing workspace:")
		XCTAssertTrue(prompt.question.hasPrefix("Quick safety check: Is this a project you created or one you trust?"))
		XCTAssertTrue(prompt.question.hasSuffix("review what's in this folder first."))
		XCTAssertEqual(prompt.options.map(\.label), ["No, exit", "Yes, I trust this folder"])
		// A trust check, not a permission: the agent's labels, no approve/deny, "No, exit" destructive.
		XCTAssertEqual(prompt.purpose, .trust)
		XCTAssertEqual(prompt.options.map(\.kind), [.other, .other])
		XCTAssertEqual(prompt.options.map(\.destructive), [true, false])
		XCTAssertEqual(prompt.options.map(\.number), [nil, nil])
		XCTAssertEqual(prompt.selectedIndex, 0)
		XCTAssertEqual(prompt.detail?.components(separatedBy: "\n").first, "/private/tmp/herdr-r1/sandbox")
	}

	func testCodexStyleCursorOnSecondOption() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.codexCommand))
		XCTAssertEqual(prompt.question, "Would you like to run the following command?")
		XCTAssertEqual(prompt.detail, "swift test --filter AgentPermissionTests")
		XCTAssertEqual(prompt.command, "swift test --filter AgentPermissionTests")
		XCTAssertEqual(prompt.action, .run)
		XCTAssertNil(prompt.title)
		XCTAssertEqual(prompt.options.count, 3)
		XCTAssertEqual(prompt.options[2].label, "No, and tell Codex what to do differently (esc)")
		XCTAssertEqual(prompt.options.map(\.kind), [.approve, .approve, .deny])
		XCTAssertEqual(prompt.selectedIndex, 1)
		XCTAssertEqual(prompt.cancelKey, "esc")
	}

	func testRealCodexTrustDialog() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.codexTrust))
		XCTAssertTrue(prompt.question.hasPrefix("Trust this folder? Codex can read"))
		XCTAssertTrue(prompt.question.hasSuffix("Your trust decision will be saved."))
		XCTAssertNil(prompt.title)
		XCTAssertEqual(prompt.options.map(\.label), ["Trust and continue", "Back to Agent Command Center"])
		XCTAssertEqual(prompt.purpose, .trust)
		XCTAssertEqual(prompt.options.map(\.kind), [.other, .other])
		XCTAssertEqual(prompt.options.map(\.destructive), [false, true])
		XCTAssertEqual(prompt.selectedIndex, 0)
		XCTAssertEqual(prompt.keys(for: "2"), ["down", "enter"])
	}

	func testBoxedDialogJoinsWrappedOption() throws {
		let prompt = try XCTUnwrap(PermissionParser.parse(Self.boxed))
		XCTAssertEqual(prompt.question, "Do you want to make this edit to App.swift?")
		XCTAssertEqual(prompt.title, "Edit file")
		XCTAssertEqual(prompt.detail, "Sources/App.swift")
		XCTAssertEqual(prompt.options.map(\.label), [
			"Yes", "Yes, allow all edits during this session", "No, and tell Claude what to do differently (esc)",
		])
	}

	func testUnparseableScreensGiveNil() {
		XCTAssertNil(PermissionParser.parse(""))
		XCTAssertNil(PermissionParser.parse("❯ Try \"edit <filepath> to...\"\n  -- INSERT -- ⏸ manual mode on"))
		XCTAssertNil(PermissionParser.parse("Results:\n 1. only one item\n"))
		XCTAssertNil(PermissionParser.parse("Steps\n 1. First\n 3. Third\n"))
	}

	func testPromptIDIgnoresTheCursorButNotTheDialog() throws {
		let first = try XCTUnwrap(PermissionParser.parse(Self.claudeBash))
		let moved = try XCTUnwrap(
			PermissionParser.parse(
				Self.claudeBash.replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
					.replacingOccurrences(of: "   4. No", with: " ❯ 4. No")))
		XCTAssertEqual(moved.selectedIndex, 3)
		XCTAssertEqual(first.id, moved.id)
		let other = try XCTUnwrap(PermissionParser.parse(Self.claudeBash.replacingOccurrences(of: "curl -sI", with: "rm -rf")))
		XCTAssertNotEqual(first.id, other.id)
	}

	// MARK: Choice → keys

	func testKeysMoveFromTheCursorThenConfirm() throws {
		let bash = try XCTUnwrap(PermissionParser.parse(Self.claudeBash))
		XCTAssertEqual(bash.keys(for: "1"), ["enter"])
		XCTAssertEqual(bash.keys(for: "2"), ["down", "enter"])
		XCTAssertEqual(bash.keys(for: "4"), ["down", "down", "down", "enter"])
		XCTAssertNil(bash.keys(for: "5"))
		XCTAssertNil(bash.keys(for: "yes"))

		let codex = try XCTUnwrap(PermissionParser.parse(Self.codexCommand))
		XCTAssertEqual(codex.keys(for: "1"), ["up", "enter"])
		XCTAssertEqual(codex.keys(for: "3"), ["down", "enter"])

		let trust = try XCTUnwrap(PermissionParser.parse(Self.claudeTrust))
		XCTAssertEqual(trust.keys(for: "2"), ["down", "enter"])
	}

	func testWithoutACursorOnlyNumberedOptionsMap() {
		var prompt = PermissionPrompt(
			title: nil, question: "Proceed?", detail: nil,
			options: [
				.init(id: "1", label: "Yes", kind: .approve, number: 1), .init(id: "2", label: "No", kind: .deny, number: 2),
			], selectedIndex: nil, cancelKey: nil)
		XCTAssertEqual(prompt.keys(for: "2"), ["2"])
		prompt.options[1].number = nil
		XCTAssertNil(prompt.keys(for: "2"))
	}

	func testKindsOfLabels() {
		XCTAssertEqual(PermissionParser.kind(of: "Yes"), .approve)
		XCTAssertEqual(PermissionParser.kind(of: "Allow once"), .approve)
		XCTAssertEqual(PermissionParser.kind(of: "No, and tell Claude what to do differently (esc)"), .deny)
		XCTAssertEqual(PermissionParser.kind(of: "Deny"), .deny)
		XCTAssertEqual(PermissionParser.kind(of: "Nothing"), .other)
		XCTAssertEqual(PermissionParser.kind(of: "Yesterday"), .other)
	}

	// MARK: Tracker

	final class FakeAgent: @unchecked Sendable {
		let lock = NSLock()
		var status = "blocked"
		var screen = AgentPermissionTests.claudeBash
		var sent: [[String]] = []

		var reader: PermissionTracker.Reader {
			PermissionTracker.Reader(
				status: { [self] _ in
					lock.lock()
					defer { lock.unlock() }
					return (status, ["name": "r1claude", "cwd": "/tmp/sandbox"])
				},
				screen: { [self] _ in
					lock.lock()
					defer { lock.unlock() }
					return screen
				},
				sendKeys: { [self] _, keys in
					lock.lock()
					sent.append(keys)
					lock.unlock()
				})
		}
	}

	final class RecordingPush: PushNotifier, @unchecked Sendable {
		let lock = NSLock()
		var pushed: [ApprovalPush] = []
		var resolved: [String] = []
		var isConfigured: Bool { true }
		func notifyApproval(_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool)
			-> String
		{
			lock.lock()
			pushed.append(push)
			lock.unlock()
			return "sent"
		}
		func notifyResolved(requestID: String) {
			lock.lock()
			resolved.append(requestID)
			lock.unlock()
		}
	}

	final class Events: @unchecked Sendable {
		let lock = NSLock()
		var list: [(String, [String: Any])] = []
		func add(_ name: String, _ data: [String: Any]) {
			lock.lock()
			list.append((name, data))
			lock.unlock()
		}
		var names: [String] {
			lock.lock()
			defer { lock.unlock() }
			return list.map(\.0)
		}
	}

	func makeTracker(_ agent: FakeAgent, _ push: RecordingPush, _ events: Events) -> PermissionTracker {
		PermissionTracker(
			reader: agent.reader, publish: { events.add($0, $1) }, push: push, devices: { [] }, lastDevice: { nil },
			now: { 1000 })
	}

	func testCurrentParsesPushesOnceAndAnswers() throws {
		let agent = FakeAgent()
		let push = RecordingPush()
		let events = Events()
		let tracker = makeTracker(agent, push, events)

		let first = try tracker.current("w1:p1")
		let permission = try XCTUnwrap(first["permission"] as? [String: Any])
		let promptID = try XCTUnwrap(permission["prompt_id"] as? String)
		let requestID = try XCTUnwrap(permission["request_id"] as? String)
		XCTAssertTrue(requestID.hasPrefix("apr_"))
		XCTAssertEqual(permission["question"] as? String, "Do you want to proceed?")
		XCTAssertEqual((permission["options"] as? [[String: Any]])?.count, 4)
		XCTAssertNotNil(first["screen"] as? String)
		XCTAssertEqual(push.pushed.map(\.requestID), [requestID])
		XCTAssertEqual(push.pushed.first?.requester, "r1claude")
		XCTAssertEqual(push.pushed.first?.summary, "Bash command")
		XCTAssertEqual(push.pushed.first?.project, "sandbox")

		// The same dialog again: same request, no second push.
		let again = try tracker.current("w1:p1")
		XCTAssertEqual((again["permission"] as? [String: Any])?["request_id"] as? String, requestID)
		XCTAssertEqual(push.pushed.count, 1)
		XCTAssertNotNil(tracker.annotate(["id": "w1:p1", "status": "blocked"])["permission"])
		XCTAssertNil(tracker.annotate(["id": "w1:p1", "status": "working"])["permission"])

		let answer = try tracker.answer("w1:p1", choice: "4", promptID: promptID)
		XCTAssertEqual(answer["kind"] as? String, "deny")
		XCTAssertEqual(agent.sent, [["down", "down", "down", "enter"]])
		XCTAssertNil(tracker.entry("w1:p1"))
		XCTAssertEqual(push.resolved, [requestID])
		XCTAssertEqual(events.names, ["agent.permission", "approval.resolved"])
	}

	func testAnswerRefusesAChangedOrGonePrompt() throws {
		let agent = FakeAgent()
		let tracker = makeTracker(agent, RecordingPush(), Events())
		let promptID = try XCTUnwrap((try tracker.current("w1:p1")["permission"] as? [String: Any])?["prompt_id"] as? String)

		agent.screen = Self.claudeBash.replacingOccurrences(of: "curl -sI", with: "rm -rf")
		XCTAssertThrowsError(try tracker.answer("w1:p1", choice: "1", promptID: promptID)) { error in
			XCTAssertEqual((error as? APIError)?.code, "permission_changed")
		}
		agent.screen = Self.claudeBash
		XCTAssertThrowsError(try tracker.answer("w1:p1", choice: "9", promptID: promptID)) { error in
			XCTAssertEqual((error as? APIError)?.status, 400)
		}
		agent.screen = "nothing to see"
		XCTAssertThrowsError(try tracker.answer("w1:p1", choice: "1", promptID: promptID)) { error in
			XCTAssertEqual((error as? APIError)?.code, "permission_unparsed")
		}
		agent.status = "working"
		XCTAssertThrowsError(try tracker.answer("w1:p1", choice: "1", promptID: promptID)) { error in
			XCTAssertEqual((error as? APIError)?.code, "not_blocked")
		}
		XCTAssertEqual(agent.sent, [])
		XCTAssertThrowsError(try tracker.answer("tmux:main:0.0", choice: "1", promptID: promptID))
	}

	func testUnparsedBlockedAgentReturnsTheScreen() throws {
		let agent = FakeAgent()
		agent.screen = "Some free-form question the parser cannot read"
		let push = RecordingPush()
		let tracker = makeTracker(agent, push, Events())
		let answer = try tracker.current("w1:p1")
		XCTAssertTrue(answer["permission"] is NSNull)
		XCTAssertEqual(answer["screen"] as? String, agent.screen)
		XCTAssertEqual(push.pushed.count, 0)
	}

	func testStatusEventsOpenAndClearTheDialog() throws {
		let agent = FakeAgent()
		let push = RecordingPush()
		let events = Events()
		let tracker = makeTracker(agent, push, events)
		tracker.observe("agent.status", ["id": "w1:p1", "status": "blocked", "name": "r1claude"])
		try waitUntil { tracker.entry("w1:p1") != nil }
		let requestID = try XCTUnwrap(tracker.entry("w1:p1")?.requestID)
		XCTAssertTrue(tracker.isPending(requestID))
		XCTAssertEqual(tracker.entry(requestID: requestID)?.agentID, "w1:p1")
		tracker.observe("agent.status", ["id": "w1:p1", "status": "working"])
		try waitUntil { tracker.entry("w1:p1") == nil }
		try waitUntil { push.resolved == [requestID] }
		tracker.observe("agent.status", ["id": "tmux:s:0.0", "status": "blocked"])
		tracker.observe("agents.changed", [:])
		XCTAssertEqual(push.pushed.count, 1)
	}

	private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition() {
			guard Date() < deadline else { return XCTFail("condition not met in time") }
			Thread.sleep(forTimeInterval: 0.01)
		}
	}

	// MARK: Routes

	func testRoutesAndAnswerValidation() throws {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/permission")?.name, "agents.permission")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1:p1/permission")?.name, "agents.permission.answer")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1:p1/permission")?.auth, .signed)
		XCTAssertEqual(LinkAPI.match("GET", "/v1/permissions")?.name, "permissions.list")
		XCTAssertNil(LinkAPI.match("DELETE", "/v1/agents/w1:p1/permission"))

		let ok = try LinkAPI.parsePermissionAnswer(["choice": "2", "prompt_id": "0123456789abcdef"])
		XCTAssertEqual(ok.choice, "2")
		for bad: [String: Any] in [
			["choice": "yes", "prompt_id": "0123456789abcdef"], ["choice": 2, "prompt_id": "0123456789abcdef"],
			["choice": "2", "prompt_id": "0123456789ABCDEF"], ["choice": "2"], ["keys": ["enter"]],
		] {
			XCTAssertThrowsError(try LinkAPI.parsePermissionAnswer(bad))
		}
	}
}
