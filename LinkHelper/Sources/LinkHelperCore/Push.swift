import CryptoKit
import Foundation
import WhisperaLink

/// One approval to push about: who should hear first and what a named push may say.
public struct ApprovalPush: Sendable, Equatable {
	public var requestID: String
	public var expiresAt: Int
	/// The broker's `prefer_device`.
	public var preferDevice: String?
	/// The helper's `last_device` when the approval arrived.
	public var lastDevice: String?
	public var requester: String
	public var key: String
	public var summary: String
	public var project: String
	/// An agent's dialog (permission or ask): the agent, the dialog's prompt id and the event
	/// (`permission` | `ask`). With these the sealed text is the contract §1 superset; nil for
	/// broker approvals, which keep the plain `PushPayload`.
	public var agentID: String?
	public var promptID: String?
	public var event: String?

	public init(
		requestID: String, expiresAt: Int, preferDevice: String? = nil, lastDevice: String? = nil,
		requester: String = "", key: String = "", summary: String = "", project: String = "",
		agentID: String? = nil, promptID: String? = nil, event: String? = nil
	) {
		self.agentID = agentID
		self.promptID = promptID
		self.event = event
		self.requestID = requestID
		self.expiresAt = expiresAt
		self.preferDevice = preferDevice
		self.lastDevice = lastDevice
		self.requester = requester
		self.key = key
		self.summary = summary
		self.project = project
	}
}

/// Wakes paired phones when an approval arrives. The helper never holds APNs credentials: it
/// asks the account backend's `POST /v1/notify` to push on its behalf (PROTOCOL §10 moved to
/// the backend). Results are best effort and never delay `approval.ack` (§8: ack within 2 s).
public protocol PushNotifier: Sendable {
	var isConfigured: Bool { get }
	/// Starts pushing `push` to `devices` (preferred device first, the rest later while
	/// `isPending` holds). Returns the §8 ack value: `sent` (enqueued), `unconfigured`,
	/// `no_token` (nobody to push to) or `failed`.
	func notifyApproval(_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool)
		-> String
	/// The approval left `pending`: clear the banner on every device pushed for it.
	func notifyResolved(requestID: String)
}

/// What a sealed push carries beyond `PushPayload` (contract §1-2): sorted-keys JSON, so old
/// phones that decode only title/body/request_id still open it.
struct SealedPushPayload: Codable, Equatable {
	var agent_id: String
	var body: String
	var category: String
	var event: String
	var prompt_id: String?
	var request_id: String
	var thread: String
	var title: String

	static func category(for event: String) -> String {
		switch event {
		case "permission": return "WL_PERMISSION"
		case "ask": return "WL_ASK"
		default: return "WL_AGENT"
		}
	}

	static func thread(_ agentID: String) -> String { "agent-\(agentID)" }

	init(agentID: String, event: String, promptID: String? = nil, text: PushPayload) {
		agent_id = agentID
		body = text.body
		category = Self.category(for: event)
		self.event = event
		prompt_id = promptID
		request_id = text.request_id
		thread = Self.thread(agentID)
		title = text.title
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}
}

/// No backend configured yet (accounts arrive with step 11): every send is a no-op.
public struct UnconfiguredPush: PushNotifier {
	public init() {}
	public var isConfigured: Bool { false }
	public func notifyApproval(
		_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool
	) -> String {
		"unconfigured"
	}
	public func notifyResolved(requestID: String) {}
}

/// Seals named approval pushes (WLP1) for each phone: the Mac's account agreement key and the
/// phone's verified one (from the account's peer list). AccountLink keeps it current.
public final class PushSealer: @unchecked Sendable {
	private let lock = NSLock()
	private var macID: String?
	private var agreementKey: LinkAgreementKey?
	private var macName = ""
	private var phoneKeys: [String: LinkPublicKey] = [:]

	public init() {}

	public func configure(macID: String?, agreementKey: LinkAgreementKey?, macName: String) {
		lock.lock()
		self.macID = macID
		self.agreementKey = agreementKey
		self.macName = macName
		if macID == nil { phoneKeys = [:] }
		lock.unlock()
	}

	/// The phones pushes may be sealed to: only those the owner confirmed (AccountLink filters).
	public func setPhones(_ phones: [TrustedDevice]) {
		lock.lock()
		phoneKeys = Dictionary(phones.map { ($0.id, $0.agreementKey) }, uniquingKeysWith: { first, _ in first })
		lock.unlock()
	}

	/// Phone keys by id directly (tests; `setPhones` is the account path).
	func setPhoneKeys(_ keys: [String: LinkPublicKey]) {
		lock.lock()
		phoneKeys = keys
		lock.unlock()
	}

	/// The Mac's name as named pushes say it ("on <Mac>").
	var name: String {
		lock.lock()
		defer { lock.unlock() }
		return macName
	}

	/// Whether `phoneID` can be sealed to at all.
	func canSeal(phoneID: String) -> Bool { symmetricKey(phoneID: phoneID) != nil }

	private func symmetricKey(phoneID: String) -> SymmetricKey? {
		lock.lock()
		let macID = self.macID
		let key = agreementKey
		let phone = phoneKeys[phoneID]
		lock.unlock()
		guard let macID, let key, let phone else { return nil }
		return try? PushSealing.deriveKey(agreementKey: key, peerKey: phone, phoneID: phoneID, macID: macID)
	}

	/// The `sealed` blob for `phoneID`, or nil when the phone or this Mac has no agreement key.
	/// An agent's dialog seals the §1 superset; a broker approval the plain `PushPayload`.
	public func seal(_ push: ApprovalPush, phoneID: String) -> String? {
		guard let symmetric = symmetricKey(phoneID: phoneID) else { return nil }
		let payload = PushPayload.named(
			requester: push.requester, key: push.key, summary: push.summary, project: push.project, macName: name,
			requestID: push.requestID)
		if let agentID = push.agentID, let event = push.event,
			let data = try? SealedPushPayload(agentID: agentID, event: event, promptID: push.promptID, text: payload)
				.encoded(),
			let sealed = try? PushSealing.seal(data, requestID: push.requestID, key: symmetric)
		{
			return sealed
		}
		// Too long for WLP1 (long ids): the plain payload still opens on every phone.
		return try? PushSealing.seal(payload, key: symmetric)
	}

	/// Seals raw plaintext (an agent event's JSON) for `phoneID`.
	func seal(_ plaintext: Data, requestID: String, phoneID: String) -> String? {
		guard let symmetric = symmetricKey(phoneID: phoneID) else { return nil }
		return try? PushSealing.seal(plaintext, requestID: requestID, key: symmetric)
	}
}

/// Pushes through the account backend (step 12 routing, contract §3): the preferred device
/// first — the broker's `prefer_device`, else the helper's `last_device`, else the most recently
/// paired phone — then the others after `fallbackAfter` seconds if the approval is still
/// pending, or at once when the preferred push did not go out or the preferred device cannot
/// be pushed. Every device pushed for a request gets `approval.resolved` when it resolves.
public final class RelayPush: PushNotifier, @unchecked Sendable {
	public typealias Notify =
		@Sendable (_ deviceID: String, _ kind: NotifyKind?, _ requestID: String?, _ sealed: String?) async throws ->
		String
	private let notify: Notify
	private let sealer: PushSealer?
	private let fallbackAfter: TimeInterval
	private let log: OpsLog
	private let lock = NSLock()
	private var requests: [String: RequestState] = [:]
	static let sendCap: TimeInterval = 12
	static let forgetAfter: TimeInterval = 900

	private final class RequestState {
		var pushed: [String] = []
		var resolved = false
		var nextOrder = 1
	}

	/// Agent events (`agent.event`, contract §2) through the same backend.
	public let events: AgentEventSender

	public init(
		notify: @escaping Notify, sealer: PushSealer? = nil, fallbackAfter: TimeInterval = 20, log: OpsLog = .null,
		events: AgentEventSender = UnconfiguredEventSender()
	) {
		self.notify = notify
		self.sealer = sealer
		self.fallbackAfter = fallbackAfter
		self.log = log
		self.events = events
	}

	public convenience init(
		client: RelayClient, sealer: PushSealer? = nil, fallbackAfter: TimeInterval = 20, log: OpsLog = .null,
		transport: LinkTransport = URLSessionLinkTransport()
	) {
		self.init(
			notify: { deviceID, kind, requestID, sealed in
				try await client.notify(deviceID, kind: kind, requestID: requestID, sealed: sealed).push
			}, sealer: sealer, fallbackAfter: fallbackAfter, log: log,
			events: RelayEventSender(client: client, transport: transport))
	}

	public var isConfigured: Bool { true }

	/// Who is pushed first and who later. `preferred` is nil when the chosen device cannot be
	/// pushed (unknown, revoked, not an account device): then everyone goes at once.
	static func plan(_ devices: [DeviceRecord], preferDevice: String?, lastDevice: String?) -> (
		preferred: DeviceRecord?, others: [DeviceRecord]
	) {
		let eligible = devices.filter { !$0.isRevoked && $0.origin == .account && $0.approveConfirmed }.sorted {
			($0.createdAt, $0.deviceID) > ($1.createdAt, $1.deviceID)
		}
		let wanted = preferDevice ?? lastDevice ?? eligible.first?.deviceID
		guard let wanted, let preferred = eligible.first(where: { $0.deviceID == wanted }) else {
			return (nil, eligible)
		}
		return (preferred, eligible.filter { $0.deviceID != preferred.deviceID })
	}

	public func notifyApproval(
		_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool
	) -> String {
		let (preferred, others) = Self.plan(devices, preferDevice: push.preferDevice, lastDevice: push.lastDevice)
		guard preferred != nil || !others.isEmpty else { return "no_token" }
		lock.lock()
		if requests[push.requestID] == nil { requests[push.requestID] = RequestState() }
		lock.unlock()
		let fallbackAfter = self.fallbackAfter
		DispatchQueue.global().async { [self] in
			guard let preferred else {
				log("push.route", ["request_id": push.requestID, "detail": "preferred=none fallback=now"])
				pushAll(others, push)
				return
			}
			let outcome = pushOne(preferred, push)
			guard !others.isEmpty else { return }
			if outcome != "sent" {
				log("push.route", ["request_id": push.requestID, "detail": "fallback=now preferred=\(outcome)"])
				pushAll(others, push)
				return
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + fallbackAfter) { [self] in
				guard isPending() else {
					log("push.route", ["request_id": push.requestID, "detail": "fallback=skipped not_pending"])
					return
				}
				log("push.route", ["request_id": push.requestID, "detail": "fallback=after_\(Int(fallbackAfter))s"])
				pushAll(others, push)
			}
		}
		DispatchQueue.global().asyncAfter(deadline: .now() + Self.forgetAfter) { [weak self] in
			self?.forget(push.requestID)
		}
		return "sent"
	}

	public func notifyResolved(requestID: String) {
		lock.lock()
		guard let state = requests[requestID], !state.resolved else {
			lock.unlock()
			return
		}
		state.resolved = true
		let targets = state.pushed
		state.pushed = []
		lock.unlock()
		guard !targets.isEmpty else { return }
		DispatchQueue.global().async { [self] in
			for device in targets { pushResolved(device, requestID: requestID) }
		}
	}

	private func forget(_ requestID: String) {
		lock.lock()
		requests[requestID] = nil
		lock.unlock()
	}

	private func pushAll(_ devices: [DeviceRecord], _ push: ApprovalPush) {
		for device in devices { _ = pushOne(device, push) }
	}

	@discardableResult
	private func pushOne(_ device: DeviceRecord, _ push: ApprovalPush) -> String {
		lock.lock()
		let state = requests[push.requestID]
		let order = state?.nextOrder ?? 0
		state?.nextOrder += 1
		lock.unlock()
		let sealed = device.pushText == .named ? sealer?.seal(push, phoneID: device.deviceID) : nil
		let outcome = send(device.deviceID, .approval, push.requestID, sealed)
		log(
			"push",
			[
				"device": device.deviceID, "request_id": push.requestID,
				"detail": "order=\(order) kind=approval text=\(sealed == nil ? "generic" : "named") push=\(outcome)",
			])
		guard outcome == "sent" else { return outcome }
		lock.lock()
		let resolvedMeanwhile = state?.resolved ?? false
		if !resolvedMeanwhile { state?.pushed.append(device.deviceID) }
		lock.unlock()
		// The approval resolved while this push was on its way: clear it right away.
		if resolvedMeanwhile { pushResolved(device.deviceID, requestID: push.requestID) }
		return outcome
	}

	private func pushResolved(_ deviceID: String, requestID: String) {
		let outcome = send(deviceID, .approvalResolved, requestID, nil)
		log(
			"push",
			["device": deviceID, "request_id": requestID, "detail": "kind=approval.resolved push=\(outcome)"])
	}

	private func send(_ deviceID: String, _ kind: NotifyKind, _ requestID: String, _ sealed: String?) -> String {
		let semaphore = DispatchSemaphore(value: 0)
		let box = ResultBox()
		let notify = self.notify
		Task {
			do {
				box.value = try await notify(deviceID, kind, requestID, sealed)
			} catch {
				box.value = "failed"
			}
			semaphore.signal()
		}
		return semaphore.wait(timeout: .now() + Self.sendCap) == .timedOut ? "failed" : (box.value ?? "failed")
	}

	private final class ResultBox: @unchecked Sendable {
		var value: String?
	}
}

/// The notifier the daemon hands out, whose backend can change while it runs: unconfigured until
/// the Mac joins an account, then the relay (step 11), unconfigured again after sign-out.
public final class SwitchablePush: PushNotifier, @unchecked Sendable {
	private let lock = NSLock()
	private var inner: PushNotifier

	public init(_ inner: PushNotifier = UnconfiguredPush()) {
		self.inner = inner
	}

	public func replace(with notifier: PushNotifier) {
		lock.lock()
		inner = notifier
		lock.unlock()
	}

	fileprivate var current: PushNotifier {
		lock.lock()
		defer { lock.unlock() }
		return inner
	}

	public var isConfigured: Bool { current.isConfigured }

	public func notifyApproval(
		_ push: ApprovalPush, devices: [DeviceRecord], isPending: @escaping @Sendable () -> Bool
	) -> String {
		current.notifyApproval(push, devices: devices, isPending: isPending)
	}

	public func notifyResolved(requestID: String) {
		current.notifyResolved(requestID: requestID)
	}
}

/// Agent events follow the approval backend: the relay's sender while on an account, else none.
extension SwitchablePush: AgentEventSender {
	private var events: AgentEventSender { (current as? RelayPush)?.events ?? UnconfiguredEventSender() }

	public var isEventConfigured: Bool { events.isEventConfigured }

	public func sendEvent(deviceID: String, kind: String, requestID: String, sealed: String?) async -> String {
		await events.sendEvent(deviceID: deviceID, kind: kind, requestID: requestID, sealed: sealed)
	}
}
