import Foundation
import WhisperaAgents
import XCTest

@testable import LinkHelperCore

/// The Mac's ask tracker and routes over a model of Claude Code's two-question form (the
/// parsers and the key driver are tested against real screens in agent-tui-protocol).
final class AgentAskTrackerTests: XCTestCase {
	/// Two single-select questions with tabs and a review, drawn like Claude Code 2.1.312.
	final class FakeForm: AgentAskTerminal, @unchecked Sendable {
		let lock = NSLock()
		var questions = [("Fruit", "Which fruit?", ["Apple", "Pear"]), ("Size", "Which size?", ["Small", "Large"])]
		/// Claude Code's dim `│` left of a question wider than 80 columns (agent-tui-protocol
		/// Fixtures/cc-gutter-*), on the step and in the review.
		func shown(_ text: String) -> String { text.count > 80 ? "│ \(text)" : text }
		/// Keys that are accepted but do nothing.
		var swallow: Set<String> = []
		var step = 0
		var cursor = 0
		var answers: [String?] = [nil, nil]
		var other = ["", ""]
		var submitted: [String]?
		var sent: [[String]] = []
		var typed: [String] = []
		var status = "blocked"
		/// A pane narrower than the tab bar: Claude Code clips every header but the active one,
		/// and the footer wraps (herdr then reports the agent `idle`).
		var narrow = false
		/// A harness like herdr-core: text that is not plain keys only goes in pasted with Enter.
		var pasteOnly = false
		var pasted: [String] = []
		/// Esc cancelled the form.
		var cancelled = false

		func header(_ index: Int) -> String {
			let full = questions[index].0
			return narrow && index != step && full.count > 5 ? String(full.prefix(4 + (index + step) % 3)) + "…" : full
		}

		func read() throws -> AskTerminalScreen {
			lock.lock()
			defer { lock.unlock() }
			if submitted != nil || cancelled { return AskTerminalScreen(text: "\n⏺ thanks\n\n❯ \n") }
			var bar = "←  "
			var lit = "←  "
			for index in questions.indices {
				let cell = "\(answers[index] == nil ? "☐" : "☒") \(header(index))"
				bar += cell + "  "
				lit += index == step ? "\u{1B}[48;2;177;185;249m \(cell)  \u{1B}[0m" : cell + "  "
			}
			bar += "✔ Submit  →"
			lit += "✔ Submit  →"
			var body = ["", "❯ ask", String(repeating: "─", count: 40)]
			if step == questions.count {
				body += [bar, "", "Review your answers", ""]
				for (index, q) in questions.enumerated() { body += [" " + shown("● \(q.1)"), "   → \(answers[index] ?? "")"] }
				body += ["", "Ready to submit your answers?", "", (cursor == 0 ? "❯ " : "  ") + "1. Submit answers", (cursor == 1 ? "❯ " : "  ") + "2. Cancel"]
				return AskTerminalScreen(text: body.joined(separator: "\n"), ansi: body.joined(separator: "\n"))
			}
			let q = questions[step]
			var rows = ["", shown(q.1), ""]
			for (index, label) in q.2.enumerated() { rows += [(cursor == index ? "❯ " : "  ") + "\(index + 1). \(label)", "     About \(label)."] }
			rows.append((cursor == q.2.count ? "❯ " : "  ") + "\(q.2.count + 1). " + (other[step].isEmpty ? "Type something." : other[step]))
			rows += [String(repeating: "─", count: 40), "  \(q.2.count + 2). Chat about this", ""]
			rows += narrow ? ["Enter to select · Tab/Arrow keys to navigate · Esc to", "cancel"] : ["Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
			let plain = (body + [bar] + rows).joined(separator: "\n")
			let ansi = (body + [lit] + rows).joined(separator: "\n")
			return AskTerminalScreen(text: plain, ansi: ansi)
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
			typed.append(text)
			other[step] += text
		}

		func canType(_ text: String) -> Bool { !pasteOnly || text.allSatisfy { $0.isLetter && $0.isASCII || $0 == " " } }

		func typeAndEnter(_ text: String) throws {
			lock.lock()
			defer { lock.unlock() }
			pasted.append(text)
			other[step] += text
			press("enter")
		}

		func press(_ key: String) {
			let n = step < questions.count ? questions[step].2.count : 1
			let onOther = step < questions.count && cursor == n
			switch key {
			case "up": cursor = max(0, cursor - 1)
			case "down": cursor = min(n + 1, cursor + 1)
			case "tab": if !onOther, step < questions.count { step += 1; cursor = 0 }
			case "shift+tab": if !onOther, step > 0 { step -= 1; cursor = 0 }
			case "ctrl+u": if onOther { other[step] = "" }
			case "esc": cancelled = true
			case "enter":
				if step == questions.count {
					if cursor == 0 { submitted = answers.map { $0 ?? "" } }
				} else if cursor < n {
					answers[step] = questions[step].2[cursor]; step += 1; cursor = 0
				} else if onOther, !other[step].isEmpty {
					answers[step] = other[step]; step += 1; cursor = 0
				}
			default: break
			}
		}
	}

	typealias Push = AgentPermissionTests.RecordingPush
	typealias Events = AgentPermissionTests.Events

	func makeTracker(_ form: FakeForm, _ push: Push, _ events: Events) -> AskTracker {
		let permissions = PermissionTracker(
			reader: PermissionTracker.Reader(
				status: { _ in (form.status, [:]) }, screen: { _ in try form.read().text }, sendKeys: { _, _ in }),
			publish: { events.add($0, $1) }, push: push, devices: { [] }, lastDevice: { nil }, now: { 1000 })
		return AskTracker(
			reader: AskTracker.Reader(
				status: { _ in (form.status, ["name": "asker", "cwd": "/tmp/asks-sandbox"]) }, terminal: { _ in form }),
			permissions: permissions, publish: { events.add($0, $1) }, push: push, devices: { [] }, lastDevice: { nil },
			now: { 1000 }, poll: 0.001, timeout: 0.1)
	}

	func testGetDiscoversPushesOnceAndPostAnswers() throws {
		let form = FakeForm()
		let push = Push()
		let events = Events()
		let tracker = makeTracker(form, push, events)

		let first = try tracker.current("w1:p1")
		let ask = try XCTUnwrap(first["ask"] as? [String: Any])
		XCTAssertEqual(ask["complete"] as? Bool, true, "GET reads every tab")
		XCTAssertEqual(ask["kind"] as? String, "form")
		XCTAssertEqual((ask["questions"] as? [[String: Any]])?.map { $0["text"] as? String }, ["Which fruit?", "Which size?"])
		XCTAssertEqual(form.step, 0, "discovery returns to the first question")
		XCTAssertTrue(form.sent.allSatisfy { $0 == ["tab"] || $0 == ["shift+tab"] })
		let promptID = try XCTUnwrap(ask["prompt_id"] as? String)
		let requestID = try XCTUnwrap(ask["request_id"] as? String)
		XCTAssertEqual(push.pushed.map(\.requestID), [requestID])
		XCTAssertEqual(push.pushed.first?.requester, "asker")
		XCTAssertEqual(push.pushed.first?.key, "your answer")

		// Reading again keeps the request.
		_ = try tracker.current("w1:p1")
		XCTAssertEqual(push.pushed.count, 1)
		XCTAssertEqual(tracker.annotate(["id": "w1:p1"])["ask"].flatMap { ($0 as? [String: Any])?["prompt_id"] as? String }, promptID)
		XCTAssertEqual(tracker.all().count, 1)

		XCTAssertThrowsError(try tracker.answer("w1:p1", promptID: promptID, answers: [.init(question: 0, optionIDs: ["1"])]))
		let result = try tracker.answer("w1:p1", promptID: promptID, answers: [
			.init(question: 0, optionIDs: ["2"]), .init(question: 1, other: "Medium"),
		])
		XCTAssertEqual(result["source"] as? String, "claude")
		XCTAssertEqual(form.submitted, ["Pear", "Medium"])
		XCTAssertEqual(form.typed, ["Medium"])
		XCTAssertNil(tracker.entry("w1:p1"))
		XCTAssertEqual(push.resolved, [requestID])
		XCTAssertEqual(events.names, ["agent.ask", "approval.resolved"])
	}

	/// 2026-10-29: a 3-question form from the iPad stopped at Submit because the review's
	/// `│ ● …` line for the long question was skipped.
	func testLongQuestionWithGutterSubmits() throws {
		let form = FakeForm()
		form.questions[1].1 = "For the Notes app, what platform scope should competitor and market numbers cover?"
		let tracker = makeTracker(form, Push(), Events())
		let ask = try XCTUnwrap(try tracker.current("w1:p1")["ask"] as? [String: Any])
		XCTAssertEqual((ask["questions"] as? [[String: Any]])?.last?["text"] as? String, form.questions[1].1, "no gutter in the text")
		let promptID = try XCTUnwrap(ask["prompt_id"] as? String)
		_ = try tracker.answer("w1:p1", promptID: promptID, answers: [.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["2"])])
		XCTAssertEqual(form.submitted, ["Apple", "Large"])
	}

	func testStopPartwayTellsThePhoneWhere() throws {
		let form = FakeForm()
		let tracker = makeTracker(form, Push(), Events())
		let promptID = try XCTUnwrap((try tracker.current("w1:p1")["ask"] as? [String: Any])?["prompt_id"] as? String)
		form.swallow = ["down"]
		XCTAssertThrowsError(try tracker.answer("w1:p1", promptID: promptID, answers: [
			.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["2"]),
		])) { error in
			let api = error as? APIError
			XCTAssertEqual(api?.code, "ask_stuck")
			XCTAssertEqual(
				api?.message,
				"Your Mac stopped at question 2 of 2 (Size) (move the cursor). 1 of 2 answers are entered there but nothing was submitted. Finish on the Mac, or try again.")
			let reached = api?.extra["reached"] as? [String: Any]
			XCTAssertEqual(reached?["question"] as? Int, 1)
			XCTAssertEqual(reached?["step"] as? Int, 1)
			XCTAssertEqual(reached?["answered"] as? [Int], [0])
			XCTAssertEqual(reached?["review"] as? Bool, false)
		}
		XCTAssertNil(form.submitted)
		XCTAssertEqual(form.answers, ["Apple", nil])
		let cached = try XCTUnwrap(tracker.entry("w1:p1"))
		XCTAssertEqual(cached.ask.questions.map(\.answered), [true, false], "the phone sees what the form shows")
		// Once the key lands, answering again from the phone finishes it.
		form.swallow = []
		_ = try tracker.answer("w1:p1", promptID: cached.ask.id, answers: [
			.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["2"]),
		])
		XCTAssertEqual(form.submitted, ["Apple", "Large"])
	}

	func testStalePromptIDSendsNothing() throws {
		let form = FakeForm()
		let tracker = makeTracker(form, Push(), Events())
		_ = try tracker.current("w1:p1")
		form.sent = []
		XCTAssertThrowsError(try tracker.answer("w1:p1", promptID: "0000000000000000", answers: [
			.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["1"]),
		])) { error in
			XCTAssertEqual((error as? APIError)?.code, "ask_changed")
		}
		XCTAssertTrue(form.sent.isEmpty)
	}

	func testAnsweredOnTheMacIsChangedNotRetyped() throws {
		let form = FakeForm()
		let tracker = makeTracker(form, Push(), Events())
		let promptID = try XCTUnwrap((try tracker.current("w1:p1")["ask"] as? [String: Any])?["prompt_id"] as? String)
		// The owner answers at the Mac before the phone does.
		try form.send(keys: ["enter", "enter", "enter"])
		form.sent = []
		XCTAssertThrowsError(try tracker.answer("w1:p1", promptID: promptID, answers: [
			.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["1"]),
		])) { error in
			XCTAssertEqual((error as? APIError)?.code, "ask_gone")
		}
		XCTAssertTrue(form.sent.isEmpty)
	}

	func testPermissionPromptsAreListedAsConfirmAsks() throws {
		let form = FakeForm()
		let push = Push()
		let permissions = PermissionTracker(
			reader: PermissionTracker.Reader(
				status: { _ in ("blocked", [:]) }, screen: { _ in AgentPermissionTests.claudeBash }, sendKeys: { _, _ in }),
			publish: { _, _ in }, push: push, devices: { [] }, lastDevice: { nil }, now: { 1000 })
		_ = try permissions.current("w1:p2")
		let tracker = AskTracker(
			reader: AskTracker.Reader(status: { _ in ("blocked", [:]) }, terminal: { _ in form }),
			permissions: permissions, publish: { _, _ in }, push: push, devices: { [] }, lastDevice: { nil })
		let asks = tracker.all()
		XCTAssertEqual(asks.count, 1)
		XCTAssertEqual(asks.first?["kind"] as? String, "confirm")
		XCTAssertEqual(asks.first?["source"] as? String, "menu")
		XCTAssertEqual(asks.first?["prompt_id"] as? String, permissions.entry("w1:p2")?.prompt.id)
		XCTAssertNotNil(tracker.annotate(["id": "w1:p2", "status": "blocked"])["ask"])
	}

	/// A folder-trust check is a `menu` ask with the agent's labels, never a permission, and
	/// answering it picks exactly the option the phone chose.
	func testTrustDialogIsAMenuAskNotAPermission() throws {
		let form = FakeForm()
		let push = Push()
		var sent: [[String]] = []
		let permissions = PermissionTracker(
			reader: PermissionTracker.Reader(
				status: { _ in ("blocked", [:]) }, screen: { _ in AgentPermissionTests.claudeTrust },
				sendKeys: { _, keys in sent.append(keys) }),
			publish: { _, _ in }, push: push, devices: { [] }, lastDevice: { nil }, now: { 1000 })
		let state = try permissions.current("w1:p2")
		XCTAssertTrue(state["permission"] is NSNull)
		XCTAssertEqual(state["purpose"] as? String, "trust")
		XCTAssertTrue(permissions.permissions().isEmpty, "not an approval")
		XCTAssertNil(permissions.annotate(["id": "w1:p2", "status": "blocked"])["permission"])
		XCTAssertEqual(push.pushed.first?.key, "your answer")
		let tracker = AskTracker(
			reader: AskTracker.Reader(status: { _ in ("blocked", [:]) }, terminal: { _ in form }),
			permissions: permissions, publish: { _, _ in }, push: push, devices: { [] }, lastDevice: { nil })
		let ask = try XCTUnwrap(tracker.all().first)
		XCTAssertEqual(ask["kind"] as? String, "menu")
		XCTAssertEqual(ask["purpose"] as? String, "trust")
		let options = try XCTUnwrap((ask["questions"] as? [[String: Any]])?.first?["options"] as? [[String: Any]])
		XCTAssertEqual(options.map { $0["label"] as? String }, ["No, exit", "Yes, I trust this folder"])
		XCTAssertEqual(options.map { $0["destructive"] as? Bool }, [true, nil])
		XCTAssertTrue(options.allSatisfy { $0["kind"] == nil })
		let promptID = try XCTUnwrap(ask["prompt_id"] as? String)
		_ = try tracker.answer("w1:p2", promptID: promptID, answers: [.init(question: 0, optionIDs: ["2"])])
		XCTAssertEqual(sent, [["down", "enter"]], "Yes, I trust this folder; never No, exit")
	}

	// MARK: A narrow pane (2026-10-30, a 4-question form in a 57-column pane)

	func narrowForm() -> FakeForm {
		let form = FakeForm()
		form.narrow = true
		form.status = "idle"
		form.questions = [
			("Tabs", "Which tabs?", ["Hybrid", "Guide's"]), ("Companion", "Which companion?", ["On", "Off"]),
			("Subtitles", "Which card text?", ["One line", "Two lines"]), ("Onboarding", "Which onboarding?", ["Six screens", "Voice"]),
		]
		form.answers = [nil, nil, nil, nil]
		form.other = ["", "", "", ""]
		return form
	}

	func testClippedHeadersDiscoverAndSubmit() throws {
		let form = narrowForm()
		let tracker = makeTracker(form, Push(), Events())
		let ask = try XCTUnwrap(try tracker.current("m_f20d92e50aa84fec6d05a3d84ad391ca.w3X:p1")["ask"] as? [String: Any])
		XCTAssertEqual(ask["complete"] as? Bool, true, "every clipped tab is the same ask")
		XCTAssertEqual((ask["questions"] as? [[String: Any]])?.map { $0["header"] as? String }, ["Tabs", "Companion", "Subtitles", "Onboarding"])
		XCTAssertEqual(form.step, 0)
		let promptID = try XCTUnwrap(ask["prompt_id"] as? String)
		_ = try tracker.answer("m_f20d92e50aa84fec6d05a3d84ad391ca.w3X:p1", promptID: promptID, answers: [
			.init(question: 0, optionIDs: ["1"]), .init(question: 1, optionIDs: ["2"]),
			.init(question: 2, optionIDs: ["1"]), .init(question: 3, other: "Both, voice first"),
		])
		XCTAssertEqual(form.submitted, ["Hybrid", "Off", "One line", "Both, voice first"])
	}

	func testAQuietAgentShowingAFormGetsItsCardAndPush() throws {
		let form = narrowForm()
		let push = Push()
		let events = Events()
		let tracker = makeTracker(form, push, events)
		tracker.observe("agent.status", ["id": "m_f20d92e50aa84fec6d05a3d84ad391ca.w3X:p1", "status": "done", "agent": "claude"])
		let deadline = Date().addingTimeInterval(2)
		while tracker.entry("m_f20d92e50aa84fec6d05a3d84ad391ca.w3X:p1") == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
		XCTAssertNotNil(tracker.entry("m_f20d92e50aa84fec6d05a3d84ad391ca.w3X:p1"), "herdr says done; the screen says asking")
		XCTAssertTrue(events.names.contains("agent.ask"))
		XCTAssertTrue(form.sent.isEmpty, "read only")
		// A shell or any other agent going quiet is not read.
		let other = makeTracker(form, Push(), Events())
		other.observe("agent.status", ["id": "w9:p1", "status": "idle", "agent": "shell"])
		Thread.sleep(forTimeInterval: 0.05)
		XCTAssertNil(other.entry("w9:p1"))
	}

	func testFormOnScreenBlocksTypingUntilDismissed() throws {
		let form = narrowForm()
		let events = Events()
		let tracker = makeTracker(form, Push(), events)
		let ask = try XCTUnwrap(tracker.blockingAsk("w1:p1"))
		XCTAssertEqual((ask["questions"] as? [Any])?.count, 4)
		let requestID = try XCTUnwrap(tracker.entry("w1:p1")?.requestID)
		// A Dismiss for a form that is no longer the one on screen sends nothing.
		XCTAssertThrowsError(try tracker.answerDialog("w1:p1", action: .cancel, promptID: "0123456789abcdef")) { error in
			XCTAssertEqual((error as? APIError)?.code, "dialog_changed")
		}
		XCTAssertTrue(form.sent.isEmpty)
		// The composer's "Dismiss dialog & send" (2026-11-07: refused every time with
		// agent_asking): Esc cancels the form, and its card is resolved for every phone.
		let answer = try tracker.answerDialog("w1:p1", action: .cancel, promptID: nil)
		XCTAssertEqual(answer["action"] as? String, "cancel")
		XCTAssertEqual(answer["prompt_id"] as? String, ask["prompt_id"] as? String)
		XCTAssertEqual(form.sent, [["esc"]])
		XCTAssertNil(tracker.entry("w1:p1"))
		let resolved = events.list.filter { $0.0 == "approval.resolved" }.map(\.1)
		XCTAssertEqual(resolved.last?["request_id"] as? String, requestID)
		XCTAssertEqual(resolved.last?["status"] as? String, "dismissed")
		XCTAssertNil(tracker.blockingAsk("w1:p1"), "no form: the reply goes through")
	}

	func testAFormThatStaysAfterEscIsReportedStuck() throws {
		let form = narrowForm()
		form.swallow = ["esc"]
		let tracker = makeTracker(form, Push(), Events())
		XCTAssertThrowsError(try tracker.answerDialog("w1:p1", action: .cancel, promptID: nil)) { error in
			XCTAssertEqual((error as? APIError)?.code, "dialog_stuck")
		}
		XCTAssertNotNil(tracker.blockingAsk("w1:p1"))
	}

	/// The 2026-11-07 phone report: herdr-core could not type the `?` of a free-text answer,
	/// so the form could not be submitted at all. A harness that pastes such text with Enter
	/// answers it in one step, every character intact, and the review is still checked.
	func testFreeTextAPasteOnlyHarnessCannotKeyIsPastedWithEnter() throws {
		let form = FakeForm()
		form.pasteOnly = true
		let tracker = makeTracker(form, Push(), Events())
		let ask = try XCTUnwrap(tracker.current("w1:p1")["ask"] as? [String: Any])
		let promptID = try XCTUnwrap(ask["prompt_id"] as? String)
		let text = "Do you have access to linear? \"quotes\" é 🙂 it's fine!"
		_ = try tracker.answer("w1:p1", promptID: promptID, answers: [
			.init(question: 0, other: text), .init(question: 1, other: "Medium please"),
		])
		XCTAssertEqual(form.submitted, [text, "Medium please"])
		XCTAssertEqual(form.pasted, [text], "only the text keys cannot spell is pasted")
		XCTAssertEqual(form.typed, ["Medium please"])
	}

	func testRoutesAndBodyValidation() throws {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/ask")?.name, "agents.ask")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1:p1/ask")?.name, "agents.ask.answer")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/tmux:p3/ask")?.auth, .signed)
		XCTAssertEqual(LinkAPI.match("GET", "/v1/asks")?.name, "asks.list")
		XCTAssertEqual(LinkAPI.match("GET", "/v1/asks")?.auth, .signed)
		let ok = try LinkAPI.parseAskAnswer([
			"prompt_id": "0123456789abcdef", "answers": [["question": 0, "option_ids": ["1", "3"], "other": "x"]],
		])
		XCTAssertEqual(ok.answers, [.init(question: 0, optionIDs: ["1", "3"], other: "x")])
		for bad: [String: Any] in [
			["prompt_id": "0123456789abcdef"], ["prompt_id": "xyz", "answers": [["question": 0, "option_ids": ["1"]]]],
			["prompt_id": "0123456789abcdef", "answers": []], ["prompt_id": "0123456789abcdef", "answers": [["option_ids": ["1"]]]],
			["prompt_id": "0123456789abcdef", "keys": ["enter"]],
		] {
			XCTAssertThrowsError(try LinkAPI.parseAskAnswer(bad))
		}
	}
}
