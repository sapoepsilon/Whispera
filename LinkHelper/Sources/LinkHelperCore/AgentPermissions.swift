import Foundation
import WhisperaAgents
import WhisperaLink

/// A permission dialog an agent is blocked on (roadmap R1). The parser now lives in
/// WhisperaAgents (`ChoiceMenu`, shared with the ask layer); the Mac keeps the wire shape and
/// still chooses the keys, never the phone.
typealias PermissionPrompt = ChoiceMenu
typealias PermissionParser = ChoiceMenuParser

extension ChoiceMenu {
	func json(agentID: String, requestID: String?, createdAt: Int?) -> [String: Any] {
		[
			"agent_id": agentID, "prompt_id": id, "request_id": requestID ?? NSNull(),
			"title": title ?? NSNull(), "question": question, "detail": detail ?? NSNull(),
			"options": options.enumerated().map { index, option in
				[
					"id": option.id, "label": option.label, "kind": option.kind.rawValue,
					"selected": index == selectedIndex, "destructive": option.destructive,
				] as [String: Any]
			},
			"cancel_key": cancelKey ?? NSNull(), "created_at": createdAt ?? NSNull(),
			"purpose": purpose.rawValue, "action": action?.rawValue ?? NSNull(), "tool": tool ?? NSNull(),
			"summary": summary ?? NSNull(), "command": command ?? NSNull(), "file": file ?? NSNull(),
			"diff": diff ?? NSNull(), "truncated": truncated,
		]
	}

}

/// The blocked dialogs of every agent: refreshed from herdr when an agent turns `blocked`,
/// cleared when it leaves `blocked` or is answered. A new dialog gets an `apr_` request id
/// and a push (the approval push path: generic or sealed named text); its end clears the
/// banner (`approval.resolved`).
final class PermissionTracker: @unchecked Sendable {
	struct Entry {
		var agentID: String
		var prompt: PermissionPrompt
		var requestID: String
		var createdAt: Int
	}

	/// What the Mac reads off a blocked agent's screen.
	struct Reader {
		var status: (String) throws -> (status: String, agent: [String: Any])
		var screen: (String) throws -> String
		var sendKeys: (String, [String]) throws -> Void
	}

	static let pushWindow = 300

	private let reader: Reader
	private let publish: (String, [String: Any]) -> Void
	private let push: PushNotifier
	private let devices: () -> [DeviceRecord]
	private let lastDevice: () -> String?
	private let log: OpsLog
	private let now: () -> Int
	/// How long a new dialog must stay on screen before it is published.
	private let settle: TimeInterval
	/// Whether a phone wants this push (device id, `permission` | `ask`, agent id): its
	/// notification prefs. Nil lets every confirmed phone through.
	var pushFilter: ((String, String, String) -> Bool)?
	/// A permission was allowed (the agent id); its tool call is the log's pending one.
	var onApproved: ((String) -> Void)?
	private let queue = DispatchQueue(label: "link.permissions")
	private let lock = NSLock()
	private var entries: [String: Entry] = [:]

	init(
		reader: Reader, publish: @escaping (String, [String: Any]) -> Void, push: PushNotifier,
		devices: @escaping () -> [DeviceRecord], lastDevice: @escaping () -> String?, log: OpsLog = .null,
		now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }, settle: TimeInterval = 0.4
	) {
		self.settle = settle
		self.reader = reader
		self.publish = publish
		self.push = push
		self.devices = devices
		self.lastDevice = lastDevice
		self.log = log
		self.now = now
	}

	static func isSupported(_ agentID: String) -> Bool { !agentID.hasPrefix("tmux:") }

	/// An event-hub event: `agent.status` drives the tracker; everything else is ignored.
	func observe(_ event: String, _ data: [String: Any]) {
		guard event == "agent.status", let id = data["id"] as? String, Self.isSupported(id) else { return }
		let status = data["status"] as? String ?? "unknown"
		queue.async { [self] in
			// A permission dialog the agent left by going back to work was allowed (at the Mac).
			if status == "working", let entry = entry(id), entry.prompt.isPermission { onApproved?(id) }
			if status == "blocked" {
				_ = try? refresh(id, knownStatus: status, agent: data)
			} else {
				clear(id, reason: "unblocked")
			}
		}
	}

	func entry(_ agentID: String) -> Entry? {
		lock.lock()
		defer { lock.unlock() }
		return entries[agentID]
	}

	func entry(requestID: String) -> Entry? {
		lock.lock()
		defer { lock.unlock() }
		return entries.values.first { $0.requestID == requestID }
	}

	func isPending(_ requestID: String) -> Bool { entry(requestID: requestID) != nil }

	/// Every blocked dialog the tracker read, permissions and the other menus alike (`AskTracker`
	/// lists the others as `menu` asks).
	func all() -> [Entry] {
		lock.lock()
		defer { lock.unlock() }
		return entries.values.sorted { ($0.createdAt, $0.agentID) < ($1.createdAt, $1.agentID) }
	}

	/// `GET /v1/permissions`: tool-permission prompts only. A folder-trust check, an update
	/// notice or a picker is not an approval.
	func permissions() -> [Entry] { all().filter { $0.prompt.isPermission } }

	func json(_ entry: Entry) -> [String: Any] {
		entry.prompt.json(agentID: entry.agentID, requestID: entry.requestID, createdAt: entry.createdAt)
	}

	/// The cached dialog on an agent object (`GET /v1/agents`).
	func annotate(_ agent: [String: Any]) -> [String: Any] {
		guard let id = agent["id"] as? String, agent["status"] as? String == "blocked", let entry = entry(id),
			entry.prompt.isPermission
		else {
			return agent
		}
		var agent = agent
		agent["permission"] = json(entry)
		return agent
	}

	/// `GET /v1/agents/{id}/permission`: reads the screen now. `permission` is null when the
	/// agent is not blocked or its dialog does not parse; `screen` (the detection text) comes
	/// with every blocked agent so the phone can fall back to it.
	func current(_ agentID: String) throws -> [String: Any] {
		guard Self.isSupported(agentID) else {
			return ["id": agentID, "status": "unknown", "permission": NSNull(), "screen": NSNull()]
		}
		return try refresh(agentID, knownStatus: nil, agent: nil)
	}

	@discardableResult
	private func refresh(_ agentID: String, knownStatus: String?, agent: [String: Any]?) throws -> [String: Any] {
		var status = knownStatus
		var info = agent ?? [:]
		if status == nil {
			let answer = try reader.status(agentID)
			status = answer.status
			info = answer.agent
		}
		guard status == "blocked" else {
			clear(agentID, reason: "unblocked")
			return ["id": agentID, "status": status ?? "unknown", "permission": NSNull(), "screen": NSNull()]
		}
		let (screen, parsed) = try stableRead(agentID)
		// Question forms (AskUserQuestion, request_user_input) are asks, not permissions.
		guard !AgentAskParser.isQuestionForm(screen), let prompt = parsed else {
			clear(agentID, reason: "unparsed")
			log("permission.unparsed", ["detail": "id=\(agentID)"])
			return ["id": agentID, "status": "blocked", "permission": NSNull(), "screen": screen]
		}
		let entry = store(agentID, prompt, agent: info)
		// Not a permission: the ask routes carry it as a `menu` ask.
		guard prompt.isPermission else {
			return ["id": agentID, "status": "blocked", "permission": NSNull(), "screen": screen, "purpose": prompt.purpose.rawValue]
		}
		return ["id": agentID, "status": "blocked", "permission": json(entry), "screen": screen]
	}

	/// The screen and its dialog once a new dialog reads the same twice `settle` apart: a
	/// screen caught mid-redraw (a prompt echoed before the real dialog is drawn) is never
	/// published. A dialog already known is taken at once.
	private func stableRead(_ agentID: String) throws -> (String, PermissionPrompt?) {
		var screen = try reader.screen(agentID)
		var prompt = PermissionParser.parse(screen)
		for _ in 0..<3 {
			guard settle > 0, let current = prompt, entry(agentID)?.prompt.id != current.id else { break }
			Thread.sleep(forTimeInterval: settle)
			let again = try reader.screen(agentID)
			let reparsed = PermissionParser.parse(again)
			screen = again
			prompt = reparsed
			if reparsed?.id == current.id { break }
		}
		return (screen, prompt)
	}

	private func store(_ agentID: String, _ prompt: PermissionPrompt, agent: [String: Any]) -> Entry {
		lock.lock()
		let previous = entries[agentID]
		if let previous, previous.prompt.id == prompt.id {
			entries[agentID]?.prompt = prompt
			let entry = entries[agentID]!
			lock.unlock()
			return entry
		}
		let entry = Entry(
			agentID: agentID, prompt: prompt, requestID: LinkCrypto.newPrefixedID("apr"), createdAt: now())
		entries[agentID] = entry
		lock.unlock()
		if let previous { resolved(previous, reason: "replaced") }
		log(
			"permission.pending",
			["request_id": entry.requestID, "detail": "id=\(agentID) purpose=\(prompt.purpose.rawValue) options=\(prompt.options.count)"])
		publish("agent.permission", ["id": agentID, "request_id": entry.requestID, "prompt_id": prompt.id])
		notify(entry, agent: agent)
		return entry
	}

	private func notify(_ entry: Entry, agent: [String: Any]) {
		let who = [agent["name"], agent["display_agent"], agent["agent"]].compactMap { $0 as? String }
			.first { !$0.isEmpty } ?? "An agent"
		let project = (agent["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
		let summary = entry.prompt.isPermission ? entry.prompt.title ?? entry.prompt.question : entry.prompt.question
		let requestID = entry.requestID
		let message = ApprovalPush(
			requestID: requestID, expiresAt: now() + Self.pushWindow, lastDevice: lastDevice(), requester: who,
			key: entry.prompt.isPermission ? "your approval" : "your answer", summary: summary, project: project,
			agentID: entry.agentID, promptID: entry.prompt.id, event: entry.prompt.isPermission ? "permission" : "ask")
		let event = message.event ?? "permission"
		let allowed = devices().filter { $0.approveConfirmed && (pushFilter?($0.deviceID, event, entry.agentID) ?? true) }
		let outcome = push.notifyApproval(
			message, devices: allowed, isPending: { [weak self] in
				self?.isPending(requestID) ?? false
			})
		log("permission.push", ["request_id": requestID, "detail": "push=\(outcome)"])
	}

	private func clear(_ agentID: String, reason: String) {
		lock.lock()
		let removed = entries.removeValue(forKey: agentID)
		lock.unlock()
		if let removed { resolved(removed, reason: reason) }
	}

	private func resolved(_ entry: Entry, reason: String) {
		log("permission.resolved", ["request_id": entry.requestID, "detail": "id=\(entry.agentID) reason=\(reason)"])
		publish("approval.resolved", ["request_id": entry.requestID, "status": reason])
		push.notifyResolved(requestID: entry.requestID)
	}

	/// `POST /v1/agents/{id}/permission`: re-reads the screen, checks it still shows the dialog
	/// the phone answered (`prompt_id`), and sends the keys for `choice`.
	func answer(_ agentID: String, choice: String, promptID: String) throws -> [String: Any] {
		guard Self.isSupported(agentID) else {
			throw APIError(409, "not_blocked", "this terminal has no permission prompts")
		}
		let (status, _) = try reader.status(agentID)
		guard status == "blocked" else {
			clear(agentID, reason: "unblocked")
			throw APIError(409, "not_blocked", "the agent is no longer waiting on a prompt; nothing was sent")
		}
		let screen = try reader.screen(agentID)
		guard !AgentAskParser.isQuestionForm(screen), let prompt = PermissionParser.parse(screen) else {
			throw APIError(409, "permission_unparsed", "the prompt on screen could not be read; nothing was sent")
		}
		guard prompt.id == promptID else {
			throw APIError(
				409, "permission_changed", "the prompt on screen changed; nothing was sent",
				extra: ["prompt_id": prompt.id])
		}
		guard let keys = prompt.keys(for: choice), let option = prompt.options.first(where: { $0.id == choice }) else {
			throw APIError(400, "bad_request", "choice must be one of the prompt's option ids")
		}
		if prompt.isPermission, option.kind == .approve { onApproved?(agentID) }
		try reader.sendKeys(agentID, keys)
		clear(agentID, reason: "answered")
		log("permission.answered", ["detail": "id=\(agentID) choice=\(choice) kind=\(option.kind.rawValue) keys=\(keys.count)"])
		return ["id": agentID, "prompt_id": prompt.id, "choice": choice, "kind": option.kind.rawValue, "keys": keys.count]
	}
}
