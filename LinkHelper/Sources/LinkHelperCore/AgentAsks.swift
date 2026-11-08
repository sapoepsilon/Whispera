import Foundation
import WhisperaAgents
import WhisperaHerdr
import WhisperaLink
import WhisperaTmux

/// Agents' interactive questions (Claude Code's AskUserQuestion, Codex's request_user_input),
/// answered from the phone. The question and its options come from the screen through the
/// harness-neutral ask layer (WhisperaAgents); the phone answers with option ids and text,
/// and the Mac keys them in, re-reading the screen between steps. Permission prompts stay
/// with `PermissionTracker` and are shown here as `confirm` asks, so `/v1/asks` lists both.
final class AskTracker: @unchecked Sendable {
	struct Entry {
		var agentID: String
		var ask: AgentAsk
		var requestID: String
		var createdAt: Int
	}

	/// What the Mac needs per agent: its status (nil when the harness has none, tmux) and the
	/// pane as an `AgentAskTerminal`.
	struct Reader {
		var status: (String) throws -> (status: String, agent: [String: Any])
		var terminal: (String) throws -> any AgentAskTerminal
	}

	static let pushWindow = 300
	/// Another machine's pane is read and keyed through the herdr CLI over ssh (about half a
	/// second a round trip): a key's effect gets this long to show before the driver stops.
	static let remoteTimeout: TimeInterval = 8

	private let reader: Reader
	private let permissions: PermissionTracker
	private let publish: (String, [String: Any]) -> Void
	private let push: PushNotifier
	private let devices: () -> [DeviceRecord]
	private let lastDevice: () -> String?
	private let log: OpsLog
	private let now: () -> Int
	private let poll: TimeInterval
	private let timeout: TimeInterval
	/// Whether a phone wants this push (device id, `permission` | `ask`, agent id): its
	/// notification prefs. Nil lets every confirmed phone through.
	var pushFilter: ((String, String, String) -> Bool)?
	private let queue = DispatchQueue(label: "link.asks")
	private let lock = NSLock()
	private var entries: [String: Entry] = [:]
	/// One driver at a time per agent: two phones answering at once would interleave keys.
	private var busy: Set<String> = []

	init(
		reader: Reader, permissions: PermissionTracker, publish: @escaping (String, [String: Any]) -> Void,
		push: PushNotifier, devices: @escaping () -> [DeviceRecord], lastDevice: @escaping () -> String?,
		log: OpsLog = .null, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
		poll: TimeInterval = 0.12, timeout: TimeInterval = 3
	) {
		self.reader = reader
		self.permissions = permissions
		self.publish = publish
		self.push = push
		self.devices = devices
		self.lastDevice = lastDevice
		self.log = log
		self.now = now
		self.poll = poll
		self.timeout = timeout
	}

	func driver(_ agentID: String) throws -> AgentAskDriver {
		var wait = timeout
		if case .remote = AgentRef(agentID) { wait = max(timeout, Self.remoteTimeout) }
		// hc's keys wait for ~3 s of quiet at the keyboard before they go in.
		if HerdrCoreID.isHerdrCore(agentID) { wait = max(timeout, Self.remoteTimeout) }
		return AgentAskDriver(terminal: try reader.terminal(agentID), poll: poll, timeout: wait)
	}

	/// `agent.status` events: a blocked agent is read (no keys); an agent that left `blocked`
	/// is re-read only if it had an ask, since Claude Code reports `idle` while its free-text
	/// row has focus and the ask is still up. A Claude Code or Codex agent that went quiet is
	/// read once too: herdr calls a question form `idle` when the pane is too narrow for its
	/// footer ("Esc to" wraps from "cancel"), on this Mac and on another machine alike.
	func observe(_ event: String, _ data: [String: Any]) {
		guard event == "agent.status", let id = data["id"] as? String else { return }
		let status = data["status"] as? String ?? "unknown"
		let kind = (data["agent"] as? String ?? "").lowercased()
		let quiet = Self.quietStatuses.contains(status) && (kind.hasPrefix("claude") || kind.hasPrefix("codex"))
		queue.async { [self] in
			if status == "blocked" || quiet || entry(id) != nil { _ = try? refresh(id, agent: data, discover: false) }
		}
	}

	static let quietStatuses: Set<String> = ["idle", "done", "unknown"]

	/// The ask a question form on the agent's screen is, or nil when none is up. One read, no
	/// keys. Text typed now would land in the form's free-text row (a prompt) or Esc would
	/// cancel it (Stop, Dismiss): the routes that would do that ask this first.
	func blockingAsk(_ agentID: String) -> [String: Any]? {
		guard let read = try? reader.terminal(agentID).read(),
			let screen = AgentAskParser.screen(text: read.text, ansi: read.ansi)
		else { return nil }
		let found = (try? refresh(agentID, agent: nil, discover: false))?["ask"] as? [String: Any]
		return found ?? AgentAsk(screen: screen).jsonObject
	}

	/// The 409 for a route that would type into, or cancel, the question form on screen.
	static func askingError(_ ask: [String: Any], _ message: String) -> APIError {
		APIError(409, "agent_asking", message, extra: ["ask": ask])
	}

	func entry(_ agentID: String) -> Entry? {
		lock.lock()
		defer { lock.unlock() }
		return entries[agentID]
	}

	func isPending(_ requestID: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return entries.values.contains { $0.requestID == requestID }
	}

	func json(_ entry: Entry) -> [String: Any] {
		var object = entry.ask.jsonObject
		object["agent_id"] = entry.agentID
		object["request_id"] = entry.requestID
		object["created_at"] = entry.createdAt
		return object
	}

	/// A permission prompt as an ask, under the permission's own request and prompt ids.
	func json(_ permission: PermissionTracker.Entry) -> [String: Any] {
		var object = AgentAsk(menu: permission.prompt).jsonObject
		object["agent_id"] = permission.agentID
		object["request_id"] = permission.requestID
		object["created_at"] = permission.createdAt
		return object
	}

	/// `GET /v1/asks`: every pending question form and permission prompt, oldest first.
	func all() -> [[String: Any]] {
		lock.lock()
		let asks = entries.values.map { ($0.createdAt, $0.agentID, json($0)) }
		lock.unlock()
		let menus = permissions.all().filter { entry($0.agentID) == nil }.map { ($0.createdAt, $0.agentID, json($0)) }
		return (asks + menus).sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
	}

	/// The cached ask on an agent object (`GET /v1/agents`, `/v1/agents/{id}`).
	func annotate(_ agent: [String: Any]) -> [String: Any] {
		guard let id = agent["id"] as? String else { return agent }
		var agent = agent
		if let entry = entry(id) {
			agent["ask"] = json(entry)
		} else if let permission = permissions.entry(id), agent["status"] as? String == "blocked" {
			agent["ask"] = json(permission)
		}
		return agent
	}

	/// `GET /v1/agents/{id}/ask`: reads the screen now. A form whose other tabs were not read
	/// yet is discovered (tab keys only, back to where it was) so the phone gets every question.
	func current(_ agentID: String) throws -> [String: Any] {
		do {
			return try refresh(agentID, agent: nil, discover: true)
		} catch let error as AgentAskError {
			// A form the keys could not walk (the screen changed under them): a 409 the phone
			// retries, never a 500 that leaves it without a card.
			log("ask.discover_failed", ["detail": "id=\(agentID) error=\(Self.code(error))"])
			throw Self.apiError(error)
		}
	}

	/// Reads the screen without sending anything (tmux panes in the agent list: tmux has no
	/// blocked status, so an ask there is only known by looking).
	func peek(_ agentID: String) {
		_ = try? refresh(agentID, agent: nil, discover: false)
	}

	@discardableResult
	private func refresh(_ agentID: String, agent: [String: Any]?, discover: Bool) throws -> [String: Any] {
		var info = agent ?? [:]
		var status = info["status"] as? String
		if agent == nil {
			let answer = try reader.status(agentID)
			status = answer.status
			info = answer.agent
		}
		let driver = try driver(agentID)
		let read = try driver.terminal.read()
		guard let screen = AgentAskParser.screen(text: read.text, ansi: read.ansi) else {
			clear(agentID, reason: "gone")
			// Permission prompts are read by their own tracker (herdr agents only).
			if PermissionTracker.isSupported(agentID), status == "blocked" {
				let permission = try permissions.current(agentID)
				if let entry = permissions.entry(agentID) {
					return ["id": agentID, "status": "blocked", "ask": json(entry), "screen": permission["screen"] ?? NSNull()]
				}
				return ["id": agentID, "status": "blocked", "ask": NSNull(), "screen": permission["screen"] ?? NSNull()]
			}
			if !PermissionTracker.isSupported(agentID), let menu = ChoiceMenuParser.parse(read.text) {
				// tmux has no permission tracker: its menus are answered as asks.
				let entry = store(agentID, AgentAsk(menu: menu), agent: info)
				return ["id": agentID, "status": status ?? "unknown", "ask": json(entry), "screen": read.text]
			}
			return ["id": agentID, "status": status ?? "unknown", "ask": NSNull(), "screen": status == "blocked" ? read.text : NSNull()]
		}
		var ask = entry(agentID)?.ask ?? AgentAsk(screen: screen)
		if !ask.merge(screen) { ask = AgentAsk(screen: screen) }
		if discover, !ask.complete {
			ask = try lockedDriving(agentID) { try driver.discover(ask) }
			log("ask.discovered", ["detail": "id=\(agentID) questions=\(ask.questions.count)"])
		}
		let entry = store(agentID, ask, agent: info)
		return ["id": agentID, "status": status ?? "unknown", "ask": json(entry), "screen": read.text]
	}

	private func lockedDriving<T>(_ agentID: String, _ body: () throws -> T) throws -> T {
		lock.lock()
		guard !busy.contains(agentID) else {
			lock.unlock()
			throw APIError(409, "ask_busy", "another answer to this agent is being entered; try again")
		}
		busy.insert(agentID)
		lock.unlock()
		defer {
			lock.lock()
			busy.remove(agentID)
			lock.unlock()
		}
		return try body()
	}

	/// Keeps the ask; a new one (not the same ask further along) gets a request id and a push.
	private func store(_ agentID: String, _ ask: AgentAsk, agent: [String: Any]) -> Entry {
		lock.lock()
		if var previous = entries[agentID], previous.ask.source == ask.source,
			previous.ask.questions.count == ask.questions.count,
			zip(previous.ask.questions, ask.questions).allSatisfy({ AgentAsk.sameHeader($0.header, $1.header) }),
			sameAsk(previous.ask, ask)
		{
			previous.ask = ask
			entries[agentID] = previous
			lock.unlock()
			return previous
		}
		let previous = entries[agentID]
		let entry = Entry(agentID: agentID, ask: ask, requestID: LinkCrypto.newPrefixedID("apr"), createdAt: now())
		entries[agentID] = entry
		lock.unlock()
		if let previous { resolved(previous, reason: "replaced") }
		log(
			"ask.pending",
			["request_id": entry.requestID, "detail": "id=\(agentID) kind=\(ask.kind.rawValue) questions=\(ask.questions.count)"])
		publish("agent.ask", ["id": agentID, "request_id": entry.requestID, "prompt_id": ask.id])
		notify(entry, agent: agent)
		return entry
	}

	/// The same ask read again: every question read in both matches.
	private func sameAsk(_ a: AgentAsk, _ b: AgentAsk) -> Bool {
		if a.source == .menu || b.source == .menu { return a.id == b.id }
		return zip(a.questions, b.questions).allSatisfy { x, y in
			!x.isRead || !y.isRead || (x.text == y.text && x.options.map(\.label) == y.options.map(\.label))
		}
	}

	private func notify(_ entry: Entry, agent: [String: Any]) {
		let who = [agent["name"], agent["display_agent"], agent["agent"]].compactMap { $0 as? String }
			.first { !$0.isEmpty } ?? "An agent"
		let project = (agent["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
		let first = entry.ask.questions.first { $0.isRead }
		let summary = first?.text ?? entry.ask.questions.compactMap(\.header).joined(separator: ", ")
		let requestID = entry.requestID
		let message = ApprovalPush(
			requestID: requestID, expiresAt: now() + Self.pushWindow, lastDevice: lastDevice(), requester: who,
			key: "your answer", summary: summary, project: project, agentID: entry.agentID, promptID: entry.ask.id,
			event: "ask")
		let allowed = devices().filter { $0.approveConfirmed && (pushFilter?($0.deviceID, "ask", entry.agentID) ?? true) }
		let outcome = push.notifyApproval(
			message, devices: allowed, isPending: { [weak self] in
				self?.isPending(requestID) ?? false
			})
		log("ask.push", ["request_id": requestID, "detail": "push=\(outcome)"])
	}

	private func clear(_ agentID: String, reason: String) {
		lock.lock()
		let removed = entries.removeValue(forKey: agentID)
		lock.unlock()
		if let removed { resolved(removed, reason: reason) }
	}

	private func resolved(_ entry: Entry, reason: String) {
		log("ask.resolved", ["request_id": entry.requestID, "detail": "id=\(entry.agentID) reason=\(reason)"])
		publish("approval.resolved", ["request_id": entry.requestID, "status": reason])
		push.notifyResolved(requestID: entry.requestID)
	}

	/// `POST /v1/agents/{id}/ask`: checks the screen still shows the ask the phone answered
	/// (`prompt_id`) and enters `answers` step by step. A changed screen gets nothing (409
	/// `ask_changed`); a key that does not land stops the entry (409 `ask_stuck`).
	func answer(_ agentID: String, promptID: String, answers: [AgentAskAnswer]) throws -> [String: Any] {
		if let permission = permissions.entry(agentID), permission.prompt.id == promptID {
			guard answers.count == 1, answers[0].optionIDs.count == 1, answers[0].other == nil else {
				throw APIError(400, "bad_request", "a permission prompt takes one option id")
			}
			var answer = try permissions.answer(agentID, choice: answers[0].optionIDs[0], promptID: promptID)
			answer["source"] = "menu"
			return answer
		}
		let driver = try driver(agentID)
		let ask: AgentAsk
		if let cached = entry(agentID)?.ask, cached.id == promptID {
			ask = cached
		} else {
			let read = try driver.terminal.read()
			guard let found = AgentAskParser.ask(text: read.text, ansi: read.ansi) else {
				clear(agentID, reason: "gone")
				throw APIError(409, "ask_gone", "the agent is no longer asking; nothing was sent")
			}
			guard found.id == promptID else {
				throw APIError(409, "ask_changed", "the question on screen changed; nothing was sent", extra: ["prompt_id": found.id])
			}
			ask = found
		}
		let report: AgentAskDriver.Report
		do {
			report = try lockedDriving(agentID) { try driver.submit(ask, answers: answers) }
		} catch let error as AgentAskError {
			var detail = "id=\(agentID) error=\(Self.code(error))"
			if case .stuck(let reason, let progress) = error {
				detail += " reason=\"\(reason)\""
				if let progress {
					detail += " at=\(progress.stoppedAt + 1)/\(progress.questions) answered=\(progress.answered.count) parked=\(progress.parked)"
				}
				// The phone's cached ask shows the answered tabs as the form now does.
				_ = try? refresh(agentID, agent: nil, discover: false)
			}
			log("ask.failed", ["detail": detail])
			throw Self.apiError(error, ask: ask)
		}
		clear(agentID, reason: "answered")
		log("ask.answered", ["detail": "id=\(agentID) source=\(ask.source.rawValue) steps=\(report.steps) keys=\(report.keys)"])
		return ["id": agentID, "prompt_id": ask.id, "source": ask.source.rawValue, "steps": report.steps, "keys": report.keys]
	}

	static func code(_ error: AgentAskError) -> String {
		switch error {
		case .unparsed: return "ask_gone"
		case .changed: return "ask_changed"
		case .invalidAnswer: return "bad_request"
		case .stuck: return "ask_stuck"
		}
	}

	static func apiError(_ error: AgentAskError, ask: AgentAsk? = nil) -> APIError {
		switch error {
		case .unparsed: return APIError(409, "ask_gone", "the agent is no longer asking; nothing more was sent")
		case .changed(let id):
			return APIError(
				409, "ask_changed", "the question on screen changed (answered on the Mac?); nothing more was sent",
				extra: id.map { ["prompt_id": $0] } ?? [:])
		case .invalidAnswer(let message): return APIError(400, "bad_request", message)
		case .stuck(let reason, let progress):
			guard let progress else {
				return APIError(409, "ask_stuck", "a key did not take effect (\(reason)); nothing more was sent")
			}
			var reached: [String: Any] = [
				"question": progress.stoppedAt, "questions": progress.questions, "review": progress.atReview,
				"answered": progress.answered, "parked": progress.parked,
			]
			if let step = progress.step { reached["step"] = step }
			return APIError(409, "ask_stuck", stuckMessage(reason, progress, ask: ask), extra: ["reached": reached])
		}
	}

	/// What the phone shows for a stop partway: where it stopped and what is left on the Mac.
	static func stuckMessage(_ reason: String, _ progress: AgentAskProgress, ask: AgentAsk?) -> String {
		let total = progress.questions
		let entered = progress.answered.count
		if progress.atReview {
			let what = entered == total ? "All \(total) answers are" : "\(entered) of \(total) answers are"
			return "Your Mac stopped at the review (\(reason)). \(what) entered there but not submitted: check them on the Mac and submit, or try again."
		}
		let index = progress.stoppedAt
		let header = ask.flatMap { $0.questions.indices.contains(index) ? $0.questions[index].header : nil }
		let name = header.map { " (\($0))" } ?? ""
		let left = entered == 0
			? "Nothing was submitted."
			: "\(entered) of \(total) answers are entered there but nothing was submitted."
		return "Your Mac stopped at question \(index + 1) of \(total)\(name) (\(reason)). \(left) Finish on the Mac, or try again."
	}
}

extension AgentDirectory {
	/// The pane behind an agent id as an ask terminal: this Mac's herdr over its socket, another
	/// machine's through the CLI, or a tmux pane.
	func askTerminal(_ id: String) throws -> any AgentAskTerminal {
		if id.hasPrefix("tmux:") {
			guard let tmux else { throw APIError(503, "tmux_unavailable", "tmux is not installed on this Mac") }
			return try tmux.askTerminal(id)
		}
		if let hc = try hcDirectory(id) { return try hc.askTerminal(id) }
		switch AgentRef(id) {
		case .local(let pane):
			let local = self.local
			return HerdrAskTerminal(target: pane) { method, params in try local.call(method, params) }
		case .remote(let machineID, let pane):
			let cli = self.cli
			// HerdrAskTerminal reads the screen as text, then at once as ansi: both come in one
			// round trip, and the ansi copy serves that next read only (keys clear it).
			let pending = PendingRead()
			return HerdrAskTerminal(target: pane) { method, params in
				switch method {
				case "agent.read":
					let format = params["format"] as? String ?? "text"
					let read = { (format: String) in
						["agent", "read", pane, "--source", "visible", "--lines", "80", "--format", format]
					}
					if format == "ansi", let ansi = pending.take() { return ["read": ["text": ansi]] }
					pending.clear()
					if format == "text", let both = cli.batchText(machine: machineID, [read("text"), read("ansi")]) {
						if case .success(let ansi) = both[1] { pending.put(ansi) }
						return ["read": ["text": try both[0].get()]]
					}
					return ["read": ["text": try cli.text(machine: machineID, read(format))]]
				case "agent.send_keys":
					pending.clear()
					let keys = params["keys"] as? [String] ?? []
					// The CLI reads anything starting with '-' as an option.
					guard !keys.contains(where: { $0.hasPrefix("-") }) else {
						throw APIError(400, "bad_request", "text for another machine cannot contain '-'")
					}
					return try cli.call(machine: machineID, ["agent", "send-keys", pane] + keys)
				default:
					return try cli.call(machine: machineID, ["agent", "get", pane])
				}
			}
		}
	}
}

/// The ansi screen read together with the text one (see `askTerminal`), for a second at most.
private final class PendingRead: @unchecked Sendable {
	private let lock = NSLock()
	private var value: (text: String, at: Date)?

	func put(_ text: String) {
		lock.lock()
		value = (text, Date())
		lock.unlock()
	}

	func take() -> String? {
		lock.lock()
		defer { lock.unlock() }
		guard let value, Date().timeIntervalSince(value.at) < 1 else { return nil }
		self.value = nil
		return value.text
	}

	func clear() {
		lock.lock()
		value = nil
		lock.unlock()
	}
}

/// MCP elicitation forms and other dialogs no ask or permission card answers, answered from
/// the phone (`/v1/agents/{id}/dialog`). Same one-driver-per-agent lock as the asks.
extension AskTracker {
	/// `GET /v1/agents/{id}/dialog`: the dialog on screen, and an elicitation's form with the
	/// kinds of its fields discovered (navigation keys only; the cursor is put back).
	func dialog(_ agentID: String) throws -> [String: Any] {
		let status = try reader.status(agentID).status
		let terminal = try reader.terminal(agentID)
		let text = try terminal.read().text
		var answer: [String: Any] = ["id": agentID, "status": status, "dialog": NSNull(), "form": NSNull()]
		guard let dialog = BlockedDialogParser.parse(text) else { return answer }
		answer["dialog"] = Self.json(dialog)
		if var form = ElicitationFormParser.parse(text) {
			if !form.complete {
				let driver = ElicitationDriver(terminal: terminal, poll: poll, timeout: timeout)
				do {
					form = try lockedDriving(agentID) { try driver.discover(form) }
					log("dialog.discovered", ["detail": "id=\(agentID) fields=\(form.fields.count)"])
				} catch let error as ElicitationError {
					// The form as read so far; unknown kinds stay unknown.
					log("dialog.discover_failed", ["detail": "id=\(agentID) error=\(Self.code(error))"])
				}
			}
			answer["form"] = form.jsonObject
		}
		return answer
	}

	/// `POST /v1/agents/{id}/dialog`: Accept (with values) or Decline the elicitation the phone
	/// saw (`prompt_id`), or Cancel: Esc on that form, on any other dialog, or on a blocked
	/// agent whose dialog did not parse. Each key is confirmed by reading the screen again.
	func answerDialog(_ agentID: String, action: ElicitationAction, promptID: String?) throws -> [String: Any] {
		let terminal = try reader.terminal(agentID)
		let driver = ElicitationDriver(terminal: terminal, poll: poll, timeout: timeout)
		let text = try terminal.read().text
		do {
			let report: ElicitationDriver.Report
			if let form = ElicitationFormParser.parse(text) {
				if action != .cancel || promptID != nil {
					guard let promptID else { throw APIError(400, "bad_request", "prompt_id is required to accept or decline") }
					guard form.id == promptID else {
						throw APIError(409, "dialog_changed", "the form on screen changed; nothing was sent", extra: ["prompt_id": form.id])
					}
				}
				var known = form
				if case .accept = action, !form.complete {
					known = try lockedDriving(agentID) { try driver.discover(form) }
				}
				report = try lockedDriving(agentID) { try driver.answer(known, action) }
			} else {
				guard action == .cancel else {
					throw APIError(409, "dialog_gone", "no MCP form is on screen; nothing was sent")
				}
				// Esc on a question form cancels the agent's AskUserQuestion. The phone asks for it
				// only from an explicit Dismiss (the composer's "Dismiss dialog & send" after its
				// message was refused with `agent_asking`); the card is how a form is answered.
				if let screen = AgentAskParser.screen(text: text) {
					// The phone knows the ask by the id of the whole form it was sent (every tab
					// read); the screen alone may show only some of it.
					var known = entry(agentID)?.ask
					if known?.merge(screen) != true { known = nil }
					let id = known?.id ?? AgentAsk(screen: screen).id
					if let promptID, promptID != id, promptID != AgentAsk(screen: screen).id {
						throw APIError(409, "dialog_changed", "the question on screen changed; nothing was sent", extra: ["prompt_id": id])
					}
					try lockedDriving(agentID) { try dismissAsk(agentID, terminal: terminal) }
					log("dialog.answered", ["detail": "id=\(agentID) action=cancel ask=1"])
					return ["id": agentID, "prompt_id": id, "action": "cancel", "steps": 1, "keys": 1]
				}
				if let dialog = BlockedDialogParser.parse(text) {
					report = try lockedDriving(agentID) { try driver.dismiss(dialog) }
				} else {
					try lockedDriving(agentID) { try dismissUnparsed(agentID, terminal: terminal, screen: text) }
					log("dialog.answered", ["detail": "id=\(agentID) action=cancel unparsed=1"])
					return ["id": agentID, "prompt_id": NSNull(), "action": "cancel", "steps": 1, "keys": 1]
				}
			}
			log("dialog.answered", ["detail": "id=\(agentID) action=\(report.action) steps=\(report.steps) keys=\(report.keys)"])
			return ["id": agentID, "prompt_id": report.promptID.isEmpty ? NSNull() : report.promptID, "action": report.action, "steps": report.steps, "keys": report.keys]
		} catch let error as ElicitationError {
			log("dialog.failed", ["detail": "id=\(agentID) action=\(action.name) error=\(Self.code(error))"])
			throw Self.apiError(error)
		}
	}

	/// Esc on the question form, confirmed by the form leaving the screen; its card is then
	/// resolved (`approval.resolved`, status `dismissed`) so every phone drops it.
	private func dismissAsk(_ agentID: String, terminal: any AgentAskTerminal) throws {
		let wait = try driver(agentID).timeout
		try terminal.send(keys: ["esc"])
		let deadline = Date().addingTimeInterval(wait)
		while Date() < deadline {
			Thread.sleep(forTimeInterval: poll)
			let read = try terminal.read()
			if AgentAskParser.screen(text: read.text, ansi: read.ansi) == nil {
				clear(agentID, reason: "dismissed")
				return
			}
		}
		throw ElicitationError.stuck("the question is still on screen after Esc", at: "Esc")
	}

	/// Esc on a blocked agent whose dialog no parser reads: only while the harness says it is
	/// blocked, and confirmed by the bottom of the screen changing.
	private func dismissUnparsed(_ agentID: String, terminal: any AgentAskTerminal, screen: String) throws {
		guard try reader.status(agentID).status == "blocked" else {
			throw APIError(409, "not_blocked", "the agent is not waiting on a dialog; nothing was sent")
		}
		let bottom = { (text: String) in text.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n") }
		let before = bottom(screen)
		try terminal.send(keys: ["esc"])
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			Thread.sleep(forTimeInterval: poll)
			if bottom(try terminal.read().text) != before { return }
		}
		throw ElicitationError.stuck("the screen did not change after Esc", at: "Esc")
	}

	static func json(_ dialog: BlockedDialog) -> [String: Any] {
		var object: [String: Any] = ["kind": dialog.kind.rawValue, "lines": dialog.lines]
		if let title = dialog.title { object["title"] = title }
		if let server = dialog.server { object["server"] = server }
		if let footer = dialog.footer { object["footer"] = footer }
		return object
	}

	static func code(_ error: ElicitationError) -> String {
		switch error {
		case .gone: return "dialog_gone"
		case .changed: return "dialog_changed"
		case .invalidAnswer: return "bad_request"
		case .stuck: return "dialog_stuck"
		}
	}

	static func apiError(_ error: ElicitationError) -> APIError {
		switch error {
		case .gone: return APIError(409, "dialog_gone", "the dialog is no longer on screen; nothing more was sent")
		case .changed(let id):
			return APIError(
				409, "dialog_changed", "the form on screen changed (answered on the Mac?); nothing more was sent",
				extra: id.map { ["prompt_id": $0] } ?? [:])
		case .invalidAnswer(let message): return APIError(400, "bad_request", message)
		case .stuck(let reason, let at):
			return APIError(
				409, "dialog_stuck", "Your Mac stopped at \(at) (\(reason)). Nothing was submitted: finish on the Mac, or try again.",
				extra: ["stopped_at": at])
		}
	}
}
