import Foundation
import WhisperaHerdr

/// Agents herdr is still launching (`launch_pending`). herdr reports such an agent `working`
/// for 10–40 s after it is ready on screen (Codex keeps a spinner in its title while its
/// tools start), and refuses prompts with `agent_not_ready` until the launch clears.
///
/// The phone is told the truth instead: an agent whose screen shows its idle input prompt,
/// with no "esc to interrupt" hint and no turn open in its session log, is `idle`. A prompt
/// sent meanwhile waits here (bounded) for herdr to accept it.
final class AgentStartup: @unchecked Sendable {
	struct Hooks {
		/// herdr's own agent info for a local pane (nil: no agent there).
		var raw: (String) throws -> [String: Any]?
		/// The visible screen.
		var screen: (String) throws -> String
		/// The session log has a turn open (nil: no log known yet).
		var turnOpen: (String) -> Bool?
	}

	static let source = "startup"
	/// How long a pane is followed after herdr was last seen launching it.
	static let window: TimeInterval = 120

	private let hooks: Hooks
	private let publish: (String, [String: Any]) -> Void
	private let log: OpsLog
	private let lock = NSLock()
	/// Launching panes → until when they are followed, and the status last told to phones.
	private var launching: [String: (until: Date, told: String?)] = [:]
	private var screens: [String: (at: Date, idle: Bool)] = [:]
	private var timer: DispatchSourceTimer?

	init(hooks: Hooks, publish: @escaping (String, [String: Any]) -> Void, log: OpsLog = .null) {
		self.hooks = hooks
		self.publish = publish
		self.log = log
	}

	/// The agent's input prompt is drawn and nothing runs: Claude Code's `❯` box or Codex's
	/// `›` composer, without the working hint either draws while a turn runs.
	static func idlePromptVisible(_ screen: String) -> Bool {
		let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		let lower = screen.lowercased()
		guard !lower.contains("esc to interrupt"), !lower.contains("working ("), !lower.contains("booting mcp") else { return false }
		return lines.suffix(8).contains { $0.hasPrefix("❯") || $0.hasPrefix("›") }
	}

	private func isLocal(_ id: String) -> Bool {
		guard !id.hasPrefix("tmux:"), !HerdrCoreID.isHerdrCore(id), case .local = AgentRef(id) else { return false }
		return true
	}

	/// Ready on screen though herdr still says working.
	private func readyOnScreen(_ id: String, now: Date = Date()) -> Bool {
		lock.lock()
		if let cached = screens[id], (0..<1).contains(now.timeIntervalSince(cached.at)) {
			lock.unlock()
			return cached.idle
		}
		lock.unlock()
		let idle = ((try? hooks.screen(id)).map(Self.idlePromptVisible) ?? false) && hooks.turnOpen(id) != true
		lock.lock()
		screens[id] = (now, idle)
		lock.unlock()
		return idle
	}

	private func follow(_ id: String) {
		lock.lock()
		if launching[id] == nil { launching[id] = (Date().addingTimeInterval(Self.window), nil) }
		lock.unlock()
	}

	private func forget(_ id: String) {
		lock.lock()
		launching[id] = nil
		screens[id] = nil
		lock.unlock()
	}

	/// The status a phone should see for a launching agent.
	func effective(_ id: String, status: String, launchPending: Bool, now: Date = Date()) -> String {
		guard launchPending, isLocal(id) else {
			if !launchPending { forget(id) }
			return status
		}
		follow(id)
		guard status == "working", readyOnScreen(id, now: now) else { return status }
		return "idle"
	}

	/// An agent object (`GET /v1/agents`, `GET /v1/agents/{id}`) with its status corrected.
	func annotate(_ agent: [String: Any]) -> [String: Any] {
		guard let id = agent["id"] as? String, let status = agent["status"] as? String else { return agent }
		let pending = agent["launch_pending"] as? Bool == true
		let effective = effective(id, status: status, launchPending: pending)
		lock.lock()
		if launching[id] != nil { launching[id]?.told = effective }
		lock.unlock()
		guard effective != status else { return agent }
		var agent = agent
		agent["status"] = effective
		agent["status_source"] = Self.source
		return agent
	}

	/// herdr's `agent.status` events on their way to phones.
	func correct(_ event: String, _ data: [String: Any]) -> [String: Any] {
		guard event == "agent.status", data["status"] as? String == "working", let id = data["id"] as? String, isLocal(id),
			let info = try? hooks.raw(id)
		else { return data }
		let effective = effective(id, status: "working", launchPending: info["launch_pending"] as? Bool == true)
		lock.lock()
		if launching[id] != nil { launching[id]?.told = effective }
		lock.unlock()
		guard effective != "working" else { return data }
		var data = data
		data["status"] = effective
		data["source"] = Self.source
		return data
	}

	/// Waits (at most `timeout`) until herdr takes prompts for the agent: its launch is over or
	/// it is blocked on a dialog. A prompt that still finds it launching gets `agent_not_ready`.
	func waitUntilReady(_ id: String, timeout: TimeInterval, poll: TimeInterval = 0.5) {
		guard isLocal(id) else { return }
		let deadline = Date().addingTimeInterval(timeout)
		var waited = false
		while let info = try? hooks.raw(id), info["launch_pending"] as? Bool == true,
			info["agent_status"] as? String != "blocked", Date() < deadline
		{
			waited = true
			// The phone that sent the prompt left: stop waiting for it (the caller checks the token).
			guard (try? CancelToken.sleep(poll)) != nil else { break }
		}
		if waited { log("agent.prompt_waited_ready", ["detail": "id=\(id)"]) }
	}

	func start() {
		lock.lock()
		defer { lock.unlock() }
		guard timer == nil else { return }
		let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.agent-startup"))
		source.schedule(deadline: .now() + 1, repeating: 1)
		source.setEventHandler { [weak self] in self?.tick() }
		source.resume()
		timer = source
	}

	func stop() {
		lock.lock()
		timer?.cancel()
		timer = nil
		lock.unlock()
	}

	/// Tells phones when a launching agent's screen turns ready (herdr sends no event for it).
	func tick(now: Date = Date()) {
		lock.lock()
		launching = launching.filter { $0.value.until > now }
		let ids = Array(launching.keys)
		lock.unlock()
		for id in ids {
			guard let info = try? hooks.raw(id) else {
				forget(id)
				continue
			}
			let status = (info["agent_status"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
			let pending = info["launch_pending"] as? Bool == true
			lock.lock()
			let told = launching[id]?.told
			lock.unlock()
			let effective = effective(id, status: status, launchPending: pending, now: now)
			lock.lock()
			if launching[id] != nil { launching[id]?.told = effective }
			lock.unlock()
			guard pending, let told, told != effective else { continue }
			log("agent.startup_status", ["detail": "id=\(id) status=\(effective) herdr=\(status)"])
			var event: [String: Any] = [
				"id": id, "status": effective, "agent": info["agent"] ?? NSNull(), "title": info["terminal_title_stripped"] ?? NSNull(),
				"workspace_id": info["workspace_id"] ?? NSNull(),
			]
			if effective != status { event["source"] = Self.source }
			publish("agent.status", event)
		}
	}
}
