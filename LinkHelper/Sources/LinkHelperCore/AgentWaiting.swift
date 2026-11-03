import Foundation
import WhisperaHerdr

/// Agents that wait on the owner while herdr reports them idle. Claude Code's full-screen
/// view, once scrolled up ("1 new message ↓"), keeps a permission dialog or a question
/// below the screen; herdr then classifies the pane from its title (`osc_title_idle`) and
/// no `blocked` status, card or push ever comes.
///
/// The session log tells: a turn that is open with nothing written for a few seconds is a
/// turn waiting on the owner. Such an agent is reported `blocked` (and an `agent.status`
/// event says so), and its view is scrolled back to the bottom so the dialog can be read.
/// Scrolling sends mouse-wheel-down only, and only to a screen that shows Claude Code's
/// "new message ↓" marker: herdr has no read of the part of a full-screen app's view that
/// is not drawn, and no End key.
final class AgentWaitWatch: @unchecked Sendable {
	struct Hooks {
		/// The session log shows a turn waiting on the owner.
		var waiting: (String) -> Bool
		/// Makes sure the agent's log is known (binds it if a phone never asked).
		var bind: (String) -> Void
		/// herdr's own status and agent object for the pane.
		var status: (String) throws -> (status: String, agent: [String: Any])
		/// The visible screen.
		var screen: (String) throws -> String
		/// Wheel-down to the bottom of a full-screen agent's view.
		var scrollToBottom: (String) throws -> Void
	}

	static let quietStatuses: Set<String> = ["idle", "done", "unknown"]
	/// How long after herdr last saw an agent working its log is still checked.
	static let window: TimeInterval = 30 * 60

	private let hooks: Hooks
	private let publish: (String, [String: Any]) -> Void
	private let log: OpsLog
	private let lock = NSLock()
	/// Agents herdr saw working and then quiet, until it sees them working or blocked again.
	private var candidates: [String: Date] = [:]
	private var flagged: Set<String> = []
	private var scrolled: [String: Date] = [:]
	private var timer: DispatchSourceTimer?

	init(hooks: Hooks, publish: @escaping (String, [String: Any]) -> Void, log: OpsLog = .null) {
		self.hooks = hooks
		self.publish = publish
		self.log = log
	}

	/// herdr's `agent.status` events (not the ones this class publishes).
	func observe(_ event: String, _ data: [String: Any]) {
		guard event == "agent.status", data["source"] as? String != Self.source, let id = data["id"] as? String,
			!id.hasPrefix("tmux:"), !HerdrCoreID.isHerdrCore(id), case .local = AgentRef(id)
		else { return }
		let status = data["status"] as? String ?? "unknown"
		lock.lock()
		defer { lock.unlock() }
		if Self.quietStatuses.contains(status) {
			if candidates[id] == nil { candidates[id] = Date().addingTimeInterval(Self.window) }
		} else {
			candidates[id] = nil
			flagged.remove(id)
		}
	}

	/// Seeds an agent the helper did not see go quiet (it was already idle when the helper
	/// started, or the event was missed).
	func consider(_ id: String, status: String) {
		guard Self.quietStatuses.contains(status), !id.hasPrefix("tmux:"), !HerdrCoreID.isHerdrCore(id), case .local = AgentRef(id) else { return }
		lock.lock()
		if candidates[id] == nil { candidates[id] = Date().addingTimeInterval(Self.window) }
		lock.unlock()
	}

	static let source = "session_log"

	func isWaiting(_ id: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return flagged.contains(id)
	}

	/// herdr's status as the phone should see it.
	func effective(_ id: String, _ status: String) -> String {
		Self.quietStatuses.contains(status) && isWaiting(id) ? "blocked" : status
	}

	/// An agent object with its status corrected.
	func annotate(_ agent: [String: Any]) -> [String: Any] {
		guard let id = agent["id"] as? String, let status = agent["status"] as? String else { return agent }
		consider(id, status: status)
		guard effective(id, status) != status else { return agent }
		var agent = agent
		agent["status"] = "blocked"
		agent["status_source"] = Self.source
		return agent
	}

	func start() {
		lock.lock()
		defer { lock.unlock() }
		guard timer == nil else { return }
		let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.agent-wait"))
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

	func tick(now: Date = Date()) {
		lock.lock()
		candidates = candidates.filter { $0.value > now }
		flagged.formIntersection(candidates.keys)
		let ids = Array(candidates.keys)
		lock.unlock()
		for id in ids {
			hooks.bind(id)
			let waiting = hooks.waiting(id)
			lock.lock()
			let was = flagged.contains(id)
			lock.unlock()
			if waiting { reveal(id, now: now) }
			guard waiting != was else { continue }
			guard let (status, agent) = try? hooks.status(id) else { continue }
			guard Self.quietStatuses.contains(status) else {
				// herdr sees the dialog itself now (or the agent works): its own event says so.
				lock.lock()
				candidates[id] = nil
				flagged.remove(id)
				lock.unlock()
				continue
			}
			lock.lock()
			if waiting { flagged.insert(id) } else { flagged.remove(id) }
			lock.unlock()
			log("agent.waiting", ["detail": "id=\(id) waiting=\(waiting) herdr=\(status)"])
			publish(
				"agent.status",
				[
					"id": id, "status": waiting ? "blocked" : status, "agent": agent["agent"] ?? NSNull(),
					"title": agent["title"] ?? NSNull(), "workspace_id": agent["workspace_id"] ?? NSNull(),
					"name": agent["name"] ?? NSNull(), "cwd": agent["cwd"] ?? NSNull(), "source": Self.source,
				])
		}
	}

	/// Scrolls a full-screen view that hides what is new back to its bottom, at most every
	/// few seconds per agent.
	private func reveal(_ id: String, now: Date) {
		lock.lock()
		if let last = scrolled[id], now.timeIntervalSince(last) < 3 {
			lock.unlock()
			return
		}
		lock.unlock()
		guard let screen = try? hooks.screen(id), Self.hidesNewOutput(screen) else { return }
		lock.lock()
		scrolled[id] = now
		lock.unlock()
		do {
			try hooks.scrollToBottom(id)
			log("agent.scrolled", ["detail": "id=\(id)"])
		} catch {
			log("agent.scroll_failed", ["detail": "id=\(id)"])
		}
	}

	/// Claude Code's marker for output below a scrolled-up view: "1 new message (click) ↓",
	/// "3 new messages ↓".
	static func hidesNewOutput(_ screen: String) -> Bool {
		screen.split(separator: "\n").contains { line in
			line.contains("↓") && (line.contains("new message") || line.contains("Jump to bottom"))
		}
	}
}
