import Foundation

/// What a control step reads back from herdr: the agent's status, whether an agent still runs in
/// the pane, the tail of its screen (nil when unreadable), and whether herdr still lists the pane
/// as an agent at all (it keeps a started agent's name for a moment after the process exits).
struct AgentProbe: Equatable {
	var status: String
	var present: Bool
	var screen: String?
	var listed = true

	static let gone = AgentProbe(status: "unknown", present: false, screen: nil, listed: false)
}

/// Interrupt, stop and new-tab start, each verified. herdr acknowledges that keys were written,
/// not what they did: Claude Code in vim editor mode spends the first Esc leaving INSERT mode,
/// a working Claude Code turns the first of two Ctrl-C into an interrupt and the second into
/// "clear the restored prompt", and a new tab's shell refuses `agent.start` while its rc files
/// still run (`agent_pane_busy`). So every action reads its effect back and retries within a
/// bound, and the answer says what actually happened.
struct AgentControl {
	struct Timing {
		/// How long one interrupt key gets to take effect before the next one is sent.
		var interruptSettle: TimeInterval = 1.5
		/// How long one Ctrl-C pair gets to end the agent before the next pair is sent.
		var stopSettle: TimeInterval = 4
		var stopRounds = 3
		var poll: TimeInterval = 0.1
		/// How long a new tab's shell gets to come up before `agent.start` is tried anyway.
		var shellReady: TimeInterval = 5
		/// How long `agent.start` is retried while herdr says the shell is busy.
		var startBusy: TimeInterval = 8
		var startBackoff: TimeInterval = 0.1
		var startBackoffMax: TimeInterval = 0.8

		static let standard = Timing()
	}

	/// Claude Code's and Codex's footer while a turn runs ("esc to interrupt").
	static let workingHint = "to interrupt"
	static let busyShellCodes: Set<String> = ["agent_pane_busy"]

	var timing = Timing.standard
	var now: () -> Date = Date.init
	var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

	// MARK: Interrupt

	struct InterruptReport: Equatable {
		enum Result: String { case interrupted, stillWorking = "still_working", notWorking = "not_working" }
		var result: Result
		var keys: [String]
		var status: String

		var body: [String: Any] {
			["result": result.rawValue, "interrupted": result != .stillWorking, "keys": keys, "status": status]
		}
	}

	/// The keys tried in order. Only one Ctrl-C ever: a second one at an idle prompt quits the agent.
	static func interruptLadder(_ first: String) -> [String] {
		first == "ctrl+c" ? ["ctrl+c", "esc", "esc"] : ["esc", "esc", "ctrl+c"]
	}

	/// Still working: herdr says so, and, when the screen showed the "esc to interrupt" hint
	/// before the first key, the hint is still there (herdr's status can lag the screen).
	static func isWorking(_ probe: AgentProbe, hinted: Bool) -> Bool {
		guard probe.present, probe.status == "working" else { return false }
		guard hinted, let screen = probe.screen else { return true }
		return screen.contains(workingHint)
	}

	/// Sends the ladder's next key only while the agent is still working after the last one.
	/// An agent that was not working gets the first key once (Esc also dismisses a dialog).
	func interrupt(
		first: String, probe: () throws -> AgentProbe, send: ([String]) throws -> Void
	) throws -> InterruptReport {
		let before = try probe()
		let hinted = before.screen?.contains(Self.workingHint) ?? false
		guard Self.isWorking(before, hinted: hinted) else {
			try send([first])
			return InterruptReport(result: .notWorking, keys: [first], status: before.status)
		}
		var sent: [String] = []
		var last = before
		for key in Self.interruptLadder(first) {
			try send([key])
			sent.append(key)
			if let settled = try wait(timing.interruptSettle, probe: probe, until: { !Self.isWorking($0, hinted: hinted) }) {
				return InterruptReport(result: .interrupted, keys: sent, status: settled.status)
			}
			last = (try? probe()) ?? last
		}
		return InterruptReport(result: .stillWorking, keys: sent, status: last.status)
	}

	// MARK: Stop

	struct StopReport: Equatable {
		var stopped: Bool
		var rounds: Int

		var body: [String: Any] { ["stopped": stopped, "result": stopped ? "stopped" : "still_running", "rounds": rounds] }
	}

	/// Ctrl-C twice, then waits for the agent to leave the pane; another pair when it has not
	/// (a working Claude Code needs two pairs: interrupt + clear, then exit). Done once herdr no
	/// longer lists the agent, so the phone's next list and detail no longer show it; an agent
	/// that exited but is still listed when the window ends counts too, with no more keys.
	func stop(probe: () throws -> AgentProbe, send: ([String]) throws -> Void) throws -> StopReport {
		for round in 1...max(1, timing.stopRounds) {
			try send(["ctrl+c", "ctrl+c"])
			var exited = false
			let unlisted = try wait(timing.stopSettle, probe: probe) {
				if !$0.present { exited = true }
				return !$0.listed
			}
			if unlisted != nil || exited { return StopReport(stopped: true, rounds: round) }
		}
		return StopReport(stopped: false, rounds: max(1, timing.stopRounds))
	}

	// MARK: Start in a new tab

	/// Opens a tab, waits for its shell, starts the agent (retrying while herdr calls the shell
	/// busy) and closes the tab again on any failure, so a failed start leaves nothing behind.
	/// A start the phone cancelled (`CancelToken.current`) is a failure too, even one that got as
	/// far as a running agent: the phone never learns of that tab.
	func startInNewTab(
		create: () throws -> (tab: String, pane: String), shellReady: (String) throws -> Bool,
		start: (String) throws -> [String: Any], close: (String) -> Void
	) throws -> [String: Any] {
		try CancelToken.checkCurrent()
		// Whole or not at all: a create cut off after herdr made the tab would leave it unknown.
		let created = try CancelToken.withoutCancellation { try create() }
		do {
			try CancelToken.checkCurrent()
			let readyBy = now().addingTimeInterval(timing.shellReady)
			while !((try? shellReady(created.pane)) ?? false), now() < readyBy {
				try CancelToken.checkCurrent()
				sleep(timing.poll)
			}
			let started = try startRetryingBusy { try start(created.pane) }
			try CancelToken.checkCurrent()
			return started
		} catch {
			CancelToken.withoutCancellation { close(created.tab) }
			throw error
		}
	}

	/// `agent.start` until herdr stops answering `agent_pane_busy`, with a bounded backoff.
	func startRetryingBusy(_ start: () throws -> [String: Any]) throws -> [String: Any] {
		let deadline = now().addingTimeInterval(timing.startBusy)
		var delay = timing.startBackoff
		while true {
			try CancelToken.checkCurrent()
			do {
				return try start()
			} catch let error as APIError where Self.busyShellCodes.contains(error.extra["herdr_code"] as? String ?? "") {
				guard now().addingTimeInterval(delay) < deadline else {
					throw APIError(
						503, "shell_not_ready",
						"The new terminal's shell was still starting after \(Int(timing.startBusy)) s, so no agent was started. Try again.",
						extra: ["herdr_code": error.extra["herdr_code"] ?? NSNull()])
				}
				sleep(delay)
				delay = min(delay * 2, timing.startBackoffMax)
			}
		}
	}

	/// A shell ready for `agent.start`: it has drawn its prompt (revision > 0) and runs nothing
	/// in the foreground but itself (rc files and prompt hooks fork while it starts).
	static func shellIsReady(processInfo: [String: Any], revision: Int?) -> Bool {
		guard let revision, revision > 0, let shell = WireJSON.strictInt(processInfo["shell_pid"]),
			let foreground = processInfo["foreground_processes"] as? [[String: Any]], !foreground.isEmpty
		else { return false }
		return foreground.allSatisfy { WireJSON.strictInt($0["pid"]) == shell }
	}

	// MARK: Polling

	/// The first probe that satisfies `done` within `window`, or nil.
	private func wait(_ window: TimeInterval, probe: () throws -> AgentProbe, until done: (AgentProbe) -> Bool) throws
		-> AgentProbe?
	{
		let deadline = now().addingTimeInterval(window)
		repeat {
			sleep(timing.poll)
			let current: AgentProbe
			do {
				current = try probe()
			} catch let error as APIError where error.status == 404 {
				current = .gone
			}
			if done(current) { return current }
		} while now() < deadline
		return nil
	}
}
