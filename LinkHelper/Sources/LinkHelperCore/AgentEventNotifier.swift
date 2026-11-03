import Foundation
import WhisperaLink

/// Sends `agent.event` / `agent.event.resolved` (contract §2) to one device.
public protocol AgentEventSender: Sendable {
	var isEventConfigured: Bool { get }
	/// `sent`, `unconfigured`, `no_token` or `failed`.
	func sendEvent(deviceID: String, kind: String, requestID: String, sealed: String?) async -> String
}

/// Not on an account: nothing to send through.
public struct UnconfiguredEventSender: AgentEventSender {
	public init() {}
	public var isEventConfigured: Bool { false }
	public func sendEvent(deviceID: String, kind: String, requestID: String, sealed: String?) async -> String {
		"unconfigured"
	}
}

/// `POST /v1/notify` with the new kinds, WL1-signed by the Mac's account link key.
public struct RelayEventSender: AgentEventSender {
	let client: RelayClient
	let transport: LinkTransport

	public init(client: RelayClient, transport: LinkTransport = URLSessionLinkTransport()) {
		self.client = client
		self.transport = transport
	}

	public var isEventConfigured: Bool { true }

	public func sendEvent(deviceID: String, kind: String, requestID: String, sealed: String?) async -> String {
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
			let body = try encoder.encode(
				NotifyRequest(device_id: deviceID, kind: kind, request_id: requestID, sealed: sealed))
			let request = try client.signedRequest(method: "POST", path: "/v1/notify", body: body)
			let (data, response) = try await transport.data(for: request)
			guard (200..<300).contains(response.statusCode),
				let answer = try? JSONDecoder().decode(NotifyResponse.self, from: data)
			else { return NotifyResponse.failed }
			return answer.push
		} catch {
			return NotifyResponse.failed
		}
	}
}

/// Turns the event hub's agent status into the phone's agent pushes (contract §2):
/// `turn_done` (working, then idle/done for `debounce` seconds, the session log's turn closed
/// when one is known), `subagents_done` (every subagent the agent ran this turn finished) and
/// `stopped` (it exited, errored or its pane went away mid-turn). One evt id per (agent, event,
/// turn): a repeat collapses, and the agent working again clears the banner
/// (`agent.event.resolved`). Only phones with named push text that the owner confirmed and the
/// Mac can seal to get these; their prefs (§4) filter on top.
final class AgentEventNotifier: @unchecked Sendable {
	struct Hooks {
		/// Whether the agent's session log has a turn open; nil when no log is known.
		var turnOpen: (String) -> Bool? = { _ in nil }
		/// How many subagents run now (the agent's last known info passed along); nil unknown.
		var subagentsRunning: (String, [String: Any]) -> Int? = { _, _ in nil }
		/// Whether the agent still exists; nil when that cannot be told (herdr unreachable).
		var exists: (String) -> Bool? = { _ in nil }
		/// The agent's current info (name, cwd, agent, title), when it can be read.
		var describe: (String) -> [String: Any]? = { _ in nil }
	}

	static let quietStatuses: Set<String> = ["idle", "done"]
	static let infoKeys = ["agent", "title", "name", "cwd", "display_agent"]
	static let stoppedStatuses: Set<String> = ["exited", "error", "errored", "crashed", "stopped", "dead"]

	private struct Track {
		var status = "unknown"
		var turn = 0
		/// Seen working this turn: only such a turn can end or be cut off.
		var worked = false
		var quietSince: Date?
		var quietKind = ""
		var subagentsPeak = 0
		var info: [String: Any] = [:]
		/// What fired this turn: event -> evt id.
		var fired: [String: String] = [:]
		var checkExists = false
	}

	private final class Delivery {
		var pushed: [String] = []
		var resolved = false
		let created: Date
		init(_ created: Date) { self.created = created }
	}

	/// The relay's APNs expiration: an event older than this has no banner left to clear.
	static let forgetAfter: TimeInterval = 3600

	private let hooks: Hooks
	private let sender: AgentEventSender
	private let sealer: PushSealer
	private let devices: () -> [DeviceRecord]
	private let prefs: NotificationPrefsStore?
	private let log: OpsLog
	private let now: () -> Date
	let debounce: TimeInterval
	/// How long a quiet agent whose log still has the turn open is waited on before turn_done.
	let openTurnCap: TimeInterval
	private let lock = NSLock()
	private var tracks: [String: Track] = [:]
	private var deliveries: [String: Delivery] = [:]
	private var herdrDown = false
	private var timer: DispatchSourceTimer?
	private let sends = DispatchQueue(label: "link.agent-events.send")

	init(
		hooks: Hooks, sender: AgentEventSender, sealer: PushSealer, devices: @escaping () -> [DeviceRecord],
		prefs: NotificationPrefsStore? = nil, log: OpsLog = .null, now: @escaping () -> Date = { Date() },
		debounce: TimeInterval = 3, openTurnCap: TimeInterval = 30
	) {
		self.hooks = hooks
		self.sender = sender
		self.sealer = sealer
		self.devices = devices
		self.prefs = prefs
		self.log = log
		self.now = now
		self.debounce = debounce
		self.openTurnCap = openTurnCap
	}

	// MARK: Input

	/// Every hub event; only the agent ones matter. Cheap: decisions happen in `tick`.
	func observe(_ event: String, _ data: [String: Any]) {
		switch event {
		case "agent.status":
			guard let id = data["id"] as? String else { return }
			status(id, data["status"] as? String ?? "unknown", data)
		case "agent.subagents":
			guard let id = data["id"] as? String, let running = WireJSON.strictInt(data["running"]) else { return }
			lock.lock()
			if var track = tracks[id] {
				track.subagentsPeak = max(track.subagentsPeak, running)
				tracks[id] = track
			}
			lock.unlock()
		case "agents.changed":
			lock.lock()
			for id in tracks.keys where tracks[id]?.worked == true { tracks[id]?.checkExists = true }
			lock.unlock()
		case "herdr.down":
			lock.lock()
			herdrDown = true
			lock.unlock()
		case "herdr.up":
			lock.lock()
			herdrDown = false
			lock.unlock()
		default:
			return
		}
	}

	private func status(_ id: String, _ status: String, _ data: [String: Any]) {
		var superseded: [String] = []
		let at = now()
		lock.lock()
		var track = tracks[id] ?? Track()
		for key in Self.infoKeys {
			if let value = data[key] as? String, !value.isEmpty { track.info[key] = value }
		}
		let agentMissing = (data["agent"] as? String ?? "").isEmpty
		track.status = status
		switch status {
		case "working":
			if !track.fired.isEmpty {
				superseded = Array(track.fired.values)
				track.fired = [:]
				track.turn += 1
				track.subagentsPeak = 0
			}
			track.worked = true
			track.quietSince = nil
		case _ where Self.quietStatuses.contains(status):
			if track.worked, track.quietSince == nil {
				track.quietSince = at
				track.quietKind = "turn_done"
			}
		case _ where Self.stoppedStatuses.contains(status) || (status == "unknown" && agentMissing):
			if track.worked, track.quietSince == nil || track.quietKind != "stopped" {
				track.quietSince = at
				track.quietKind = "stopped"
			}
		default:
			// blocked (a dialog, not the end) and unknown with an agent: the turn goes on.
			if status == "blocked" { track.quietSince = nil }
		}
		tracks[id] = track
		lock.unlock()
		for evt in superseded { resolve(evt) }
	}

	// MARK: Decisions

	func start() {
		lock.lock()
		defer { lock.unlock() }
		guard timer == nil else { return }
		let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.agent-events"))
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

	func tick(only: String? = nil) {
		let at = now()
		lock.lock()
		let ids = only.map { [$0] } ?? Array(tracks.keys)
		let down = herdrDown
		lock.unlock()
		for id in ids { decide(id, at: at, herdrDown: down) }
	}

	/// Asks the hooks without the lock (they may read herdr or files), then decides on the
	/// track as it is by then.
	private func decide(_ id: String, at: Date, herdrDown: Bool) {
		lock.lock()
		let snapshot = tracks[id]
		lock.unlock()
		guard let snapshot else { return }
		let exists = snapshot.checkExists && !herdrDown ? hooks.exists(id) : nil
		let running =
			snapshot.status == "working" || snapshot.subagentsPeak > 0
			? hooks.subagentsRunning(id, snapshot.info) : nil
		let quietLongEnough = snapshot.quietSince.map { at.timeIntervalSince($0) >= debounce } ?? false
		let open = quietLongEnough && snapshot.quietKind == "turn_done" ? hooks.turnOpen(id) : nil

		var fire: [String] = []
		lock.lock()
		guard var track = tracks[id] else {
			lock.unlock()
			return
		}
		let gone = exists == false
		if gone, track.worked { fire.append("stopped") }
		if exists == true { track.checkExists = false }
		if !gone, let running {
			if running > 0 {
				track.subagentsPeak = max(track.subagentsPeak, running)
			} else if track.subagentsPeak > 0 {
				track.subagentsPeak = 0
				fire.append("subagents_done")
			}
		}
		if !gone, let since = track.quietSince, at.timeIntervalSince(since) >= debounce {
			let kind = track.quietKind
			if kind == "stopped" || open != true || at.timeIntervalSince(since) >= openTurnCap {
				// A status that arrived after the hooks ran is judged on the next tick.
				if kind == "stopped" || since == snapshot.quietSince {
					fire.append(kind)
					track.quietSince = nil
					track.worked = false
				}
			}
		}
		var toSend: [(String, String)] = []
		for event in fire where track.fired[event] == nil {
			let evt = LinkCrypto.newPrefixedID("evt")
			track.fired[event] = evt
			toSend.append((event, evt))
		}
		tracks[id] = gone ? nil : track
		var info = track.info
		let turn = track.turn
		lock.unlock()
		guard !toSend.isEmpty else { return }
		if let fresh = hooks.describe(id) {
			for key in Self.infoKeys {
				if let value = fresh[key] as? String, !value.isEmpty { info[key] = value }
			}
		}
		for (event, evt) in toSend { send(event, evt: evt, agentID: id, info: info, turn: turn) }
	}

	/// The phones an event may go to: confirmed account phones with named text the Mac can seal to.
	func recipients(_ event: String, agentID: String) -> [DeviceRecord] {
		devices().filter {
			!$0.isRevoked && $0.origin == .account && $0.approveConfirmed && $0.pushText == .named
				&& sealer.canSeal(phoneID: $0.deviceID)
				&& (prefs?.allows($0.deviceID, event, agentID: agentID) ?? true)
		}
	}

	private func send(_ event: String, evt: String, agentID: String, info: [String: Any], turn: Int) {
		let targets = recipients(event, agentID: agentID)
		let text = Self.text(event, info: info, macName: sealer.name, requestID: evt)
		let payload = SealedPushPayload(agentID: agentID, event: event, text: text)
		log("agent.event", ["request_id": evt, "detail": "id=\(agentID) event=\(event) turn=\(turn) devices=\(targets.count)"])
		guard !targets.isEmpty, sender.isEventConfigured, let plaintext = try? payload.encoded() else { return }
		let at = now()
		let delivery = Delivery(at)
		lock.lock()
		deliveries = deliveries.filter { at.timeIntervalSince($0.value.created) < Self.forgetAfter }
		deliveries[evt] = delivery
		lock.unlock()
		let sender = self.sender
		for device in targets {
			guard let sealed = sealer.seal(plaintext, requestID: evt, phoneID: device.deviceID) else { continue }
			enqueue { [self] in
				let outcome = await sender.sendEvent(
					deviceID: device.deviceID, kind: "agent.event", requestID: evt, sealed: sealed)
				log("push", ["device": device.deviceID, "request_id": evt, "detail": "kind=agent.event push=\(outcome)"])
				guard outcome == NotifyResponse.sent else { return }
				if !markPushed(delivery, device.deviceID) { await sendResolved(device.deviceID, evt) }
			}
		}
	}

	/// Records a sent push; false when the event resolved while it was on its way.
	private func markPushed(_ delivery: Delivery, _ deviceID: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !delivery.resolved else { return false }
		delivery.pushed.append(deviceID)
		return true
	}

	/// The condition is over (the agent works again): clear the banner where it went.
	private func resolve(_ evt: String) {
		lock.lock()
		guard let delivery = deliveries.removeValue(forKey: evt) else {
			lock.unlock()
			return
		}
		delivery.resolved = true
		let targets = delivery.pushed
		delivery.pushed = []
		lock.unlock()
		for device in targets { enqueue { [self] in await sendResolved(device, evt) } }
	}

	private func sendResolved(_ deviceID: String, _ evt: String) async {
		let outcome = await sender.sendEvent(
			deviceID: deviceID, kind: "agent.event.resolved", requestID: evt, sealed: nil)
		log("push", ["device": deviceID, "request_id": evt, "detail": "kind=agent.event.resolved push=\(outcome)"])
	}

	/// Sends run one at a time, in order: an event's resolve never overtakes it.
	private func enqueue(_ work: @escaping @Sendable () async -> Void) {
		sends.async {
			let done = DispatchSemaphore(value: 0)
			Task {
				await work()
				done.signal()
			}
			_ = done.wait(timeout: .now() + RelayPush.sendCap)
		}
	}

	// MARK: Text

	static func text(_ event: String, info: [String: Any], macName: String, requestID: String) -> PushPayload {
		let who = [info["name"], info["display_agent"], info["agent"]].compactMap { $0 as? String }
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "An agent"
		var title: String
		switch event {
		case "turn_done": title = "\(who) is done"
		case "subagents_done": title = "\(who)'s subagents finished"
		default: title = "\(who) stopped"
		}
		let project = (info["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
		let mac = macName.trimmingCharacters(in: .whitespacesAndNewlines)
		let parts = [info["title"] as? String ?? "", project].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			+ [mac.isEmpty ? "" : "on \(mac)"]
		var body = parts.filter { !$0.isEmpty }.joined(separator: " · ")
		let cap = PushPayload.maxTextLength
		if title.count > cap { title = String(title.prefix(cap - 1)) + "…" }
		let room = cap - title.count
		if body.count > room { body = room > 1 ? String(body.prefix(room - 1)) + "…" : "" }
		return PushPayload(title: title, body: body, request_id: requestID)
	}
}
