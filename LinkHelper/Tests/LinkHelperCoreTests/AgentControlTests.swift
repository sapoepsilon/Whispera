import Foundation
import XCTest

@testable import LinkHelperCore

/// A scripted agent for `AgentControl`: how many single Esc / Ctrl-C presses a working turn
/// needs (Claude Code in vim mode needs two Esc), how many Ctrl-C pairs end it, and a clock
/// that only moves when the control sleeps.
private final class ScriptedAgent {
	var status = "working"
	var present = true
	var interruptNeeds: Int
	var pairsToExit: Int
	var hint = true
	/// herdr's status that keeps saying "working" after the screen has settled.
	var statusLags = false
	var sent: [[String]] = []
	var clock = Date(timeIntervalSince1970: 0)

	init(interruptNeeds: Int = 1, pairsToExit: Int = 1) {
		self.interruptNeeds = interruptNeeds
		self.pairsToExit = pairsToExit
	}

	func probe() throws -> AgentProbe {
		guard present else { throw APIError(404, "not_found", "agent not found") }
		let screen = "❯ essay\n" + (status == "working" && hint ? "⏵⏵ auto mode on · esc to interrupt" : "⏵⏵ auto mode on")
		return AgentProbe(status: statusLags ? "working" : status, present: true, screen: screen)
	}

	func send(_ keys: [String]) {
		sent.append(keys)
		if keys == ["ctrl+c", "ctrl+c"] {
			if status == "working" { status = "idle" }
			pairsToExit -= 1
			if pairsToExit <= 0 { present = false }
		} else if keys.count == 1, status == "working", interruptNeeds > 0 {
			interruptNeeds -= 1
			if interruptNeeds == 0 { status = "idle" }
		}
	}

	var control: AgentControl {
		var control = AgentControl()
		control.now = { [unowned self] in clock }
		control.sleep = { [unowned self] in clock.addTimeInterval($0) }
		return control
	}
}

final class AgentControlTests: XCTestCase {
	private func interrupt(_ agent: ScriptedAgent, first: String = "esc") throws -> AgentControl.InterruptReport {
		try agent.control.interrupt(first: first, probe: agent.probe, send: agent.send)
	}

	func testOneEscInterruptsAnAgentThatStopsOnTheFirstKey() throws {
		let agent = ScriptedAgent(interruptNeeds: 1)
		let report = try interrupt(agent)
		XCTAssertEqual(report.result, .interrupted)
		XCTAssertEqual(report.keys, ["esc"])
		XCTAssertEqual(report.status, "idle")
	}

	func testVimModeClaudeGetsASecondEscWhenTheFirstOnlyLeavesInsertMode() throws {
		let agent = ScriptedAgent(interruptNeeds: 2)
		let report = try interrupt(agent)
		XCTAssertEqual(report.result, .interrupted)
		XCTAssertEqual(report.keys, ["esc", "esc"])
		XCTAssertEqual(agent.sent, [["esc"], ["esc"]], "one key per step, each verified before the next")
		XCTAssertEqual(agent.clock.timeIntervalSince1970, 1.5 + 0.1, accuracy: 0.01, "the second key waits out one settle window")
	}

	func testEscalatesToOneCtrlCAndThenReportsStillWorking() throws {
		let agent = ScriptedAgent(interruptNeeds: 0)
		let report = try interrupt(agent)
		XCTAssertEqual(report.result, .stillWorking)
		XCTAssertEqual(report.keys, ["esc", "esc", "ctrl+c"])
		XCTAssertEqual(report.body["interrupted"] as? Bool, false)
		XCTAssertLessThanOrEqual(agent.clock.timeIntervalSince1970, 3 * 1.5 + 0.5, "bounded")
	}

	func testACtrlCInterruptNeverSendsASecondCtrlC() throws {
		let agent = ScriptedAgent(interruptNeeds: 0)
		let report = try interrupt(agent, first: "ctrl+c")
		XCTAssertEqual(report.keys, ["ctrl+c", "esc", "esc"])
		XCTAssertEqual(agent.sent.flatMap { $0 }.filter { $0 == "ctrl+c" }.count, 1, "two Ctrl-C at a prompt quit the agent")
	}

	func testAnAgentThatIsNotWorkingGetsTheKeyOnceAndNoRetry() throws {
		let agent = ScriptedAgent()
		agent.status = "blocked"
		let report = try interrupt(agent)
		XCTAssertEqual(report.result, .notWorking)
		XCTAssertEqual(agent.sent, [["esc"]])
		XCTAssertEqual(report.body["interrupted"] as? Bool, true)
	}

	func testTheScreenSettlingCountsWhenHerdrsStatusLags() throws {
		let agent = ScriptedAgent(interruptNeeds: 1)
		agent.statusLags = true
		let report = try interrupt(agent)
		XCTAssertEqual(report.result, .interrupted, "the 'esc to interrupt' hint left the screen")
		XCTAssertEqual(report.keys, ["esc"])
	}

	func testWithoutAHintOnlyHerdrsStatusCounts() throws {
		let agent = ScriptedAgent(interruptNeeds: 2)
		agent.hint = false
		let report = try interrupt(agent)
		XCTAssertEqual(report.keys, ["esc", "esc"])
		XCTAssertEqual(report.result, .interrupted)
	}

	func testAnAgentThatExitsWhileInterruptedCountsAsInterrupted() throws {
		let agent = ScriptedAgent(interruptNeeds: 5)
		var sends = 0
		let report = try agent.control.interrupt(first: "esc", probe: agent.probe) { keys in
			agent.send(keys)
			sends += 1
			agent.present = false
		}
		XCTAssertEqual(report.result, .interrupted)
		XCTAssertEqual(sends, 1)
	}

	// MARK: Stop

	func testStopEndsAnIdleAgentWithOnePair() throws {
		let agent = ScriptedAgent(pairsToExit: 1)
		agent.status = "idle"
		let report = try agent.control.stop(probe: agent.probe, send: agent.send)
		XCTAssertEqual(report, AgentControl.StopReport(stopped: true, rounds: 1))
		XCTAssertEqual(report.body["result"] as? String, "stopped")
	}

	func testStopSendsASecondPairToAWorkingClaude() throws {
		// The first pair interrupts and clears the prompt Claude Code puts back; the second exits.
		let agent = ScriptedAgent(pairsToExit: 2)
		let report = try agent.control.stop(probe: agent.probe, send: agent.send)
		XCTAssertEqual(report, AgentControl.StopReport(stopped: true, rounds: 2))
		XCTAssertEqual(agent.sent, [["ctrl+c", "ctrl+c"], ["ctrl+c", "ctrl+c"]])
	}

	func testStopWaitsForHerdrToForgetTheExitedAgent() throws {
		// herdr keeps a started agent's name, with no agent, for a moment after it exits.
		let agent = ScriptedAgent(pairsToExit: 1)
		agent.status = "idle"
		var probes = 0
		let report = try agent.control.stop(
			probe: {
				probes += 1
				if agent.present { return try agent.probe() }
				if probes < 5 { return AgentProbe(status: "idle", present: false, screen: ">") }
				throw APIError(404, "not_found", "agent not found")
			}, send: agent.send)
		XCTAssertEqual(report, AgentControl.StopReport(stopped: true, rounds: 1))
		XCTAssertEqual(probes, 5, "polled until herdr dropped it")
		XCTAssertEqual(agent.sent.count, 1, "no second pair for an agent that already exited")
	}

	func testStopCountsAnExitedAgentHerdrStillLists() throws {
		let agent = ScriptedAgent(pairsToExit: 1)
		let report = try agent.control.stop(
			probe: { agent.present ? try agent.probe() : AgentProbe(status: "unknown", present: false, screen: ">") },
			send: agent.send)
		XCTAssertEqual(report, AgentControl.StopReport(stopped: true, rounds: 1))
		XCTAssertEqual(agent.sent.count, 1)
	}

	func testStopGivesUpAfterThreeRoundsAndSaysSo() throws {
		let agent = ScriptedAgent(pairsToExit: 99)
		let report = try agent.control.stop(probe: agent.probe, send: agent.send)
		XCTAssertEqual(report, AgentControl.StopReport(stopped: false, rounds: 3))
		XCTAssertEqual(report.body["result"] as? String, "still_running")
		XCTAssertLessThanOrEqual(agent.clock.timeIntervalSince1970, 3 * 4 + 0.5)
	}

	// MARK: Start

	private func busy() -> APIError {
		HerdrClient.mapError("agent_pane_busy", "agent target pane w1:p2 is not an available shell")
	}

	func testStartRetriesWhileTheShellIsBusy() throws {
		let agent = ScriptedAgent()
		var calls = 0
		let answer = try agent.control.startRetryingBusy {
			calls += 1
			if calls < 3 { throw busy() }
			return ["agent": ["id": "w1:p2"]]
		}
		XCTAssertEqual(calls, 3)
		XCTAssertNotNil(answer["agent"])
		XCTAssertEqual(agent.clock.timeIntervalSince1970, 0.1 + 0.2, accuracy: 0.001, "backoff doubles")
	}

	func testStartGivesUpOnABusyShellWithAClearError() throws {
		let agent = ScriptedAgent()
		var calls = 0
		XCTAssertThrowsError(try agent.control.startRetryingBusy { calls += 1; throw busy() }) { error in
			let error = error as? APIError
			XCTAssertEqual(error?.code, "shell_not_ready")
			XCTAssertEqual(error?.status, 503)
			XCTAssertEqual(error?.extra["herdr_code"] as? String, "agent_pane_busy")
		}
		XCTAssertGreaterThan(calls, 3)
		XCTAssertLessThanOrEqual(agent.clock.timeIntervalSince1970, 8)
	}

	func testStartDoesNotRetryOtherErrors() throws {
		let agent = ScriptedAgent()
		var calls = 0
		XCTAssertThrowsError(
			try agent.control.startRetryingBusy {
				calls += 1
				throw HerdrClient.mapError("invalid_agent_kind", "no such kind")
			})
		XCTAssertEqual(calls, 1)
	}

	func testANewTabWaitsForItsShellAndIsClosedWhenTheStartFails() throws {
		let agent = ScriptedAgent()
		var polls = 0
		var started: [String] = []
		var closed: [String] = []
		let answer = try agent.control.startInNewTab(
			create: { ("w1:t2", "w1:p2") },
			shellReady: { _ in polls += 1; return polls > 3 },
			start: { started.append($0); return ["agent": ["id": $0]] },
			close: { closed.append($0) })
		XCTAssertEqual(polls, 4)
		XCTAssertEqual(started, ["w1:p2"], "agent.start only once the shell is ready")
		XCTAssertTrue(closed.isEmpty)
		XCTAssertNotNil(answer["agent"])

		XCTAssertThrowsError(
			try agent.control.startInNewTab(
				create: { ("w1:t3", "w1:p3") }, shellReady: { _ in true },
				start: { _ in throw self.busy() }, close: { closed.append($0) })
		) { XCTAssertEqual(($0 as? APIError)?.code, "shell_not_ready") }
		XCTAssertEqual(closed, ["w1:t3"], "no empty tab is left behind")
	}

	func testANewTabWhoseShellNeverSettlesIsStillTriedOnce() throws {
		let agent = ScriptedAgent()
		var started = 0
		_ = try agent.control.startInNewTab(
			create: { ("w1:t2", "w1:p2") }, shellReady: { _ in false },
			start: { _ in started += 1; return [:] }, close: { _ in XCTFail("not closed") })
		XCTAssertEqual(started, 1)
		XCTAssertGreaterThanOrEqual(agent.clock.timeIntervalSince1970, 5)
	}

	func testShellReadinessNeedsADrawnPromptAndNoForkedChild() {
		let shell: [String: Any] = ["pid": 100, "name": "zsh"]
		let child: [String: Any] = ["pid": 101, "name": "bash"]
		func info(_ fg: [[String: Any]]) -> [String: Any] { ["shell_pid": 100, "foreground_processes": fg] }
		XCTAssertTrue(AgentControl.shellIsReady(processInfo: info([shell]), revision: 1))
		XCTAssertFalse(AgentControl.shellIsReady(processInfo: info([shell]), revision: 0), "prompt not drawn yet")
		XCTAssertFalse(AgentControl.shellIsReady(processInfo: info([child, shell]), revision: 3), "rc file still running")
		XCTAssertFalse(AgentControl.shellIsReady(processInfo: info([]), revision: 3))
		XCTAssertFalse(AgentControl.shellIsReady(processInfo: [:], revision: 3))
	}
}

/// The verified controls end to end through the HTTP API against the fake herdr.
final class AgentControlAPITests: XCTestCase {
	var rig: FakeHerdrRig!
	var helper: TestDaemon!
	var phone: SoftPhone!

	override func setUp() async throws {
		rig = try FakeHerdrRig()
		let rig = self.rig!
		helper = try TestDaemon(engine: FakeEngine()) { config in
			config.herdrSocket = rig.localSocket
			config.herdrCLI = rig.cli
		}
		var control = AgentControl()
		control.timing.interruptSettle = 0.4
		control.timing.stopSettle = 0.5
		control.timing.poll = 0.05
		control.timing.startBusy = 1
		control.timing.shellReady = 1
		helper.daemon.agents.control = control
		phone = try await helper.pairedPhone()
	}

	override func tearDown() {
		helper.stop()
		rig.stop()
	}

	private func fake(_ socket: String, _ op: String, _ params: [String: Any]) throws {
		_ = try FakeHerdrRig.call(socket, "_fake." + op, params)
	}

	func testInterruptKeepsGoingUntilTheAgentStopsWorking() async throws {
		try fake(rig.localSocket, "set_interrupt", ["pane_id": "w2:p1", "needs": 2])
		let response = try await phone.call("POST", "/v1/agents/w2%3Ap1/interrupt")
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["result"] as? String, "interrupted")
		XCTAssertEqual(response.json["interrupted"] as? Bool, true)
		XCTAssertEqual(response.json["keys"] as? [String], ["esc", "esc"])
		XCTAssertEqual(response.json["id"] as? String, "w2:p1")
		let keys = try rig.writes(rig.localSocket).filter { $0.0 == "agent.send_keys" }.map { $0.1["keys"] as? [String] }
		XCTAssertEqual(keys, [["esc"], ["esc"]])
	}

	func testInterruptThatDoesNotTakeIsAnErrorThatSaysStillWorking() async throws {
		try fake(rig.localSocket, "set_interrupt", ["pane_id": "w2:p1", "needs": 0])
		let response = try await phone.call("POST", "/v1/agents/w2%3Ap1/interrupt")
		XCTAssertEqual(response.status, 409)
		XCTAssertEqual(response.errorCode, "still_working")
		let error = try XCTUnwrap(response.json["error"] as? [String: Any])
		XCTAssertEqual(error["result"] as? String, "still_working")
		XCTAssertEqual(error["keys"] as? [String], ["esc", "esc", "ctrl+c"])
		XCTAssertEqual(error["status"] as? String, "working")
	}

	func testInterruptOnAnIdleAgentSendsTheKeyOnce() async throws {
		let response = try await phone.call("POST", "/v1/agents/w1%3Ap1/interrupt", json: ["key": "ctrl+c"])
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["result"] as? String, "not_working")
		XCTAssertEqual(try rig.writes(rig.localSocket).map { $0.1["keys"] as? [String] }, [["ctrl+c"]])
	}

	func testStopWaitsUntilTheAgentIsGoneFromTheList() async throws {
		let stop = try await phone.call("POST", "/v1/agents/w1%3Ap1/stop")
		XCTAssertEqual(stop.status, 200)
		XCTAssertEqual(stop.json["stopped"] as? Bool, true)
		XCTAssertEqual(stop.json["result"] as? String, "stopped")
		let list = try await phone.call("GET", "/v1/agents")
		let ids = (list.json["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertFalse(ids.contains("w1:p1"), "the list no longer shows the stopped agent")
		let detail = try await phone.call("GET", "/v1/agents/w1%3Ap1")
		XCTAssertEqual(detail.errorCode, "not_found")
	}

	func testStartWaitsForTheNewShellAndRetriesABusyOne() async throws {
		try fake(rig.localSocket, "set_shell_boot", ["boot_polls": 3, "busy_starts": 2])
		let response = try await phone.call("POST", "/v1/agents", json: ["name": "fresh", "kind": "claude"])
		XCTAssertEqual(response.status, 200)
		let agent = try XCTUnwrap(response.json["agent"] as? [String: Any])
		XCTAssertEqual(agent["name"] as? String, "fresh")
		let requests = try rig.requests(rig.localSocket).map(\.0)
		XCTAssertEqual(requests.filter { $0 == "agent.start" }.count, 3)
		XCTAssertEqual(requests.filter { $0 == "pane.process_info" }.count, 4, "three busy polls, then ready")
		let firstStart = try XCTUnwrap(requests.firstIndex(of: "agent.start"))
		XCTAssertGreaterThan(firstStart, try XCTUnwrap(requests.lastIndex(of: "pane.process_info")))
	}

	func testAStartThatNeverGetsTheShellClosesItsTabAndSaysWhy() async throws {
		try fake(rig.localSocket, "set_shell_boot", ["busy_starts": 1000])
		let response = try await phone.call("POST", "/v1/agents", json: ["name": "stuck", "kind": "claude"])
		XCTAssertEqual(response.status, 503)
		XCTAssertEqual(response.errorCode, "shell_not_ready")
		let closed = try FakeHerdrRig.call(rig.localSocket, "_fake.closed_tabs")["tabs"] as? [String]
		XCTAssertEqual(closed?.count, 1, "the empty tab was closed")
		XCTAssertEqual(try rig.writes(rig.localSocket).last?.0, "tab.close")
	}

	func testARemoteStartRetriesAndCleansUpThroughTheCLI() async throws {
		try fake(rig.remoteSocket, "set_shell_boot", ["busy_starts": 1])
		let ok = try await phone.call("POST", "/v1/agents", json: ["name": "far", "kind": "codex", "machine": "fake-main"])
		XCTAssertEqual(ok.status, 200)
		XCTAssertEqual(try rig.writes(rig.remoteSocket).map(\.0), ["tab.create", "agent.start", "agent.start"])

		try fake(rig.remoteSocket, "set_shell_boot", ["busy_starts": 1000])
		let stuck = try await phone.call("POST", "/v1/agents", json: ["name": "stuck", "kind": "codex", "machine": "fake-main"])
		XCTAssertEqual(stuck.errorCode, "shell_not_ready")
		XCTAssertEqual(try rig.writes(rig.remoteSocket).last?.0, "tab.close")
		XCTAssertTrue(rig.cliInvocations().contains { $0.contains("close") }, "closed through `herdr tab close`")
	}
}
