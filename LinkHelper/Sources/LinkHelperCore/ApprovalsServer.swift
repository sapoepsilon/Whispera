import Foundation
import WhisperaLink
import WhisperaLinkServer

/// `approvals.sock` (broker ↔ helper) and the pending approvals table (PROTOCOL §5.6, §7, §8).
///
/// The broker opens one connection per approval and sends `approval.request`; the helper acks
/// within 2 s, publishes `approval.pending`, pushes (preferred device first), and forwards at most
/// one `approval.decision`. The helper never serialises canonical requests: it carries the
/// broker's bytes verbatim as `canonical_b64`.
public final class ApprovalsServer: @unchecked Sendable {
	static let resultWait: TimeInterval = 3
	static let requestReadTimeout: TimeInterval = 5
	static let retainResolved = 3600
	static let connectionGraceAfterExpiry = 60
	static let canonicalFields: Set<String> = [
		"v", "request_id", "nonce", "op", "key", "summary", "project", "token", "host", "caller", "via", "broker",
		"created_at", "expires_at",
	]
	static let intFields: Set<String> = ["v", "created_at", "expires_at"]
	static let displayFields = ["op", "summary", "key", "project", "token", "host", "caller", "via", "broker"]
	static let ops: Set<String> = ["save", "bws"]

	final class Approval: @unchecked Sendable {
		let requestID: String
		let canonicalB64: String
		let canonicalBytes: Data
		let canonical: [String: Any]
		let createdAt: Int
		let expiresAt: Int
		let preferDevice: String?
		var status = "pending"
		var decidedBy: String?
		var decidedAt: Int?
		var resolvedAt: Int?
		var brokerOutcome: String?
		var cancelReason: String?
		let connection: UnixConnection
		let result = DispatchSemaphore(value: 0)
		var resultSignalled = false

		init(
			requestID: String, canonicalB64: String, bytes: Data, canonical: [String: Any], preferDevice: String?,
			connection: UnixConnection
		) {
			self.requestID = requestID
			self.canonicalB64 = canonicalB64
			canonicalBytes = bytes
			self.canonical = canonical
			createdAt = canonical["created_at"] as? Int ?? 0
			expiresAt = canonical["expires_at"] as? Int ?? 0
			self.preferDevice = preferDevice
			self.connection = connection
		}

		var summary: [String: Any] {
			[
				"request_id": requestID, "created_at": createdAt, "expires_at": expiresAt,
				"op": canonical["op"] ?? "", "summary": canonical["summary"] ?? "",
			]
		}

		var view: [String: Any] {
			var display: [String: Any] = [:]
			for field in ApprovalsServer.displayFields { display[field] = canonical[field] ?? "" }
			return [
				"request_id": requestID, "status": status, "created_at": createdAt, "expires_at": expiresAt,
				"canonical_b64": canonicalB64, "display": display, "decided_by": decidedBy ?? NSNull(),
				"reason": cancelReason ?? NSNull(),
			]
		}
	}

	private let listener: UnixListener
	private let devices: DeviceRegistry
	private let publish: (String, [String: Any]) -> Void
	private let push: PushNotifier
	private let clock: @Sendable () -> Int
	private let log: OpsLog
	private let skipApprovePrecheck: Bool
	private let lastDevice: @Sendable () -> String?
	private let macApprover: () -> DeviceRecord?
	private let offerMacCard: () -> Bool
	private let lock = NSLock()
	private var changeHandler: (() -> Void)?
	private var approvals: [String: Approval] = [:]
	private var openConnections = 0
	private var stopped = false

	public init(
		socketPath: String, devices: DeviceRegistry, publish: @escaping (String, [String: Any]) -> Void,
		push: PushNotifier = UnconfiguredPush(),
		clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
		log: OpsLog = .null, skipApprovePrecheck: Bool = false, lastDevice: @escaping @Sendable () -> String? = { nil },
		macApprover: @escaping () -> DeviceRecord? = { nil }, offerMacCard: @escaping () -> Bool = { false }
	) {
		listener = UnixListener(path: socketPath)
		self.devices = devices
		self.publish = publish
		self.push = push
		self.clock = clock
		self.log = log
		self.skipApprovePrecheck = skipApprovePrecheck
		self.lastDevice = lastDevice
		self.macApprover = macApprover
		self.offerMacCard = offerMacCard
	}

	/// Called after any approval appears or changes status, on the thread that changed it. The
	/// Mac approval card refreshes from it (§8.1).
	public func onChange(_ handler: @escaping () -> Void) {
		lock.lock()
		changeHandler = handler
		lock.unlock()
	}

	private func changed() {
		lock.lock()
		let handler = changeHandler
		lock.unlock()
		handler?()
	}

	public func start() throws {
		try listener.start(
			name: "approvals-accept",
			onForeignPeer: { [log] connection in
				log("approvals.reject", ["detail": "peer uid mismatch"])
				connection.close()
			},
			handle: { [weak self] connection in self?.handle(connection) })
		let sweeper = Thread { [weak self] in
			while let self, !self.isStopped {
				Thread.sleep(forTimeInterval: 0.5)
				self.sweep()
			}
		}
		sweeper.name = "approvals-sweeper"
		sweeper.start()
	}

	public func stop() {
		lock.lock()
		stopped = true
		lock.unlock()
		listener.stop()
	}

	private var isStopped: Bool {
		lock.lock()
		defer { lock.unlock() }
		return stopped
	}

	public var isConnected: Bool {
		lock.lock()
		defer { lock.unlock() }
		return openConnections > 0
	}

	/// Decodes and validates canonical bytes per §7.1: exactly the fields, exact types, and bytes
	/// that are already the canonical serialisation of their own JSON.
	static func parseCanonical(_ canonicalB64: Any?) throws -> (Data, [String: Any]) {
		guard let text = canonicalB64 as? String, let raw = Data(base64Encoded: text) else {
			throw Malformed("canonical_b64 is not base64")
		}
		guard raw.allSatisfy({ $0 < 0x80 }), let object = WireJSON.decodeObject(raw) else {
			throw Malformed("canonical bytes are not ASCII JSON")
		}
		guard Set(object.keys) == canonicalFields else {
			throw Malformed("canonical request must have exactly the §7.1 fields")
		}
		var typed: [String: Any] = [:]
		for (key, value) in object {
			if intFields.contains(key) {
				guard let number = WireJSON.strictInt(value) else {
					throw Malformed("field \(key) has the wrong type")
				}
				typed[key] = number
			} else {
				guard let string = value as? String else { throw Malformed("field \(key) has the wrong type") }
				typed[key] = string
			}
		}
		guard typed["v"] as? Int == 1, let op = typed["op"] as? String, ops.contains(op) else {
			throw Malformed("unsupported v/op")
		}
		guard let rid = typed["request_id"] as? String, LinkCrypto.isValidPrefixedID(rid, prefix: "apr"),
			let nonce = typed["nonce"] as? String, LinkCrypto.isValidNonce(nonce)
		else { throw Malformed("bad request_id/nonce") }
		guard let created = typed["created_at"] as? Int, let expires = typed["expires_at"] as? Int,
			expires > created
		else {
			throw Malformed("expires_at must be after created_at")
		}
		guard WireJSON.pythonCanonical(typed) == raw else {
			throw Malformed("canonical bytes are not in canonical form")
		}
		// What every approver parses: no duplicate keys, and no control, bidi, zero-width or
		// line-break characters that would make a card or push read differently from the bytes.
		do {
			_ = try CanonicalApproval(bytes: raw)
		} catch let refusal as CanonicalApproval.Refusal {
			switch refusal {
			case .unsafeCharacters(let field):
				throw Malformed("unsafe characters in \(field)", code: "unsafe_characters")
			case .malformed(let detail):
				throw Malformed("refused by the approval parser: \(detail)")
			default:
				throw Malformed("refused by the approval parser")
			}
		}
		return (raw, typed)
	}

	struct Malformed: Error {
		let reason: String
		/// What `approval.error` says to the broker.
		let code: String
		init(_ reason: String, code: String = "malformed") {
			self.reason = reason
			self.code = code
		}
	}

	// MARK: Socket side

	private func handle(_ connection: UnixConnection) {
		lock.lock()
		openConnections += 1
		lock.unlock()
		var approval: Approval?
		defer {
			if let approval { brokerGone(approval) }
			connection.close()
			lock.lock()
			openConnections -= 1
			lock.unlock()
		}
		guard case .line(let line)? = try? connection.readLine(timeout: Self.requestReadTimeout), !line.isEmpty
		else { return }
		approval = accept(connection, line)
		if let approval { brokerLoop(connection, approval) }
	}

	private func accept(_ connection: UnixConnection, _ line: Data) -> Approval? {
		var rid: String?
		let approval: Approval
		do {
			guard let message = WireJSON.decodeObject(line) else { throw Malformed("not an object") }
			rid = message["request_id"] as? String
			guard message["op"] as? String == "approval.request", WireJSON.strictInt(message["v"]) == 1 else {
				throw Malformed("expected approval.request v1")
			}
			let (raw, canonical) = try Self.parseCanonical(message["canonical_b64"])
			guard canonical["request_id"] as? String == rid,
				canonical["expires_at"] as? Int == WireJSON.strictInt(message["expires_at"])
			else { throw Malformed("request_id/expires_at do not match the canonical request") }
			let prefer = (message["prefer_device"] as? String).flatMap {
				LinkCrypto.isValidDeviceID($0) ? $0 : nil
			}
			lock.lock()
			defer { lock.unlock() }
			guard let rid, approvals[rid] == nil else { throw Malformed("duplicate request_id") }
			approval = Approval(
				requestID: rid, canonicalB64: message["canonical_b64"] as? String ?? "", bytes: raw,
				canonical: canonical,
				preferDevice: prefer, connection: connection)
			approvals[rid] = approval
		} catch {
			let reason = (error as? Malformed)?.reason ?? "malformed"
			let code = (error as? Malformed)?.code ?? "malformed"
			log("approval.malformed", ["request_id": rid ?? "-", "detail": String(reason.prefix(120))])
			try? connection.sendLine([
				"op": "approval.error", "request_id": rid ?? NSNull(), "code": code,
				"message": String(reason.prefix(120)),
			])
			return nil
		}

		// Only devices the owner confirmed hear about approvals.
		let active = devices.active().filter(\.approveConfirmed)
		func field(_ name: String) -> String { approval.canonical[name] as? String ?? "" }
		let request = ApprovalPush(
			requestID: approval.requestID, expiresAt: approval.expiresAt, preferDevice: approval.preferDevice,
			lastDevice: lastDevice(), requester: field("caller"), key: field("key"), summary: field("summary"),
			project: field("project"))
		let pushStatus = push.notifyApproval(request, devices: active) { [weak self, weak approval] in
			guard let self, let approval else { return false }
			return self.isPending(approval)
		}
		let macCard = macApprover() != nil && offerMacCard()
		try? connection.sendLine([
			"op": "approval.ack", "request_id": approval.requestID,
			"devices": active.count + (macApprover() != nil ? 1 : 0), "push": pushStatus, "mac_card": macCard,
		])
		log(
			"approval.request",
			[
				"request_id": approval.requestID,
				"detail":
					"op=\(approval.canonical["op"] ?? "") push=\(pushStatus) prefer=\(approval.preferDevice ?? "-")",
			])
		publish("approval.pending", ["request_id": approval.requestID, "expires_at": approval.expiresAt])
		changed()
		return approval
	}

	private func brokerLoop(_ connection: UnixConnection, _ approval: Approval) {
		let hardEnd = approval.expiresAt + Self.connectionGraceAfterExpiry
		while !isStopped {
			checkExpiry(approval)
			if clock() > hardEnd { return }
			let result: UnixConnection.LineResult
			do {
				result = try connection.readLine(timeout: 0.25)
			} catch {
				return
			}
			switch result {
			case .timeout: continue
			case .eof: return
			case .line(let line):
				guard let message = WireJSON.decodeObject(line),
					message["request_id"] as? String == approval.requestID
				else {
					continue
				}
				switch message["op"] as? String {
				case "approval.result":
					let outcome = message["outcome"] as? String ?? "malformed"
					lock.lock()
					approval.brokerOutcome = outcome
					if outcome != "accepted" && approval.status == "approved" { approval.status = "denied" }
					lock.unlock()
					signalResult(approval)
					changed()
					log(
						"approval.result",
						["request_id": approval.requestID, "detail": "outcome=\(outcome)"])
				case "approval.cancel":
					let reason = message["reason"] as? String ?? ""
					let status = reason == "timeout" ? "expired" : "cancelled"
					if !resolve(approval, status, detail: "reason=\(reason)", reason: reason) {
						supersede(approval, status, reason)
					}
				default:
					continue
				}
			}
		}
	}

	private func signalResult(_ approval: Approval) {
		lock.lock()
		let first = !approval.resultSignalled
		approval.resultSignalled = true
		lock.unlock()
		if first { approval.result.signal() }
	}

	private func brokerGone(_ approval: Approval) {
		if !resolve(approval, "cancelled", detail: "broker_eof", reason: "broker_eof") {
			supersede(approval, "cancelled", "broker_eof")
		}
		signalResult(approval)
	}

	/// The broker cancelled or closed after a phone decision went out but before any
	/// `approval.result` (Touch ID won at the same moment): it discarded that decision, so the
	/// helper must stop reporting it (§5.6).
	private func supersede(_ approval: Approval, _ status: String, _ reason: String) {
		lock.lock()
		guard approval.status == "approved" || approval.status == "denied", approval.brokerOutcome == nil else {
			lock.unlock()
			return
		}
		approval.status = status
		approval.cancelReason = reason
		lock.unlock()
		log(
			"approval.superseded",
			["request_id": approval.requestID, "status": status, "detail": "reason=\(reason)"])
		signalResult(approval)
		changed()
	}

	/// Still waiting for a decision (the push fallback asks before waking more phones).
	private func isPending(_ approval: Approval) -> Bool {
		checkExpiry(approval)
		lock.lock()
		defer { lock.unlock() }
		return approval.status == "pending"
	}

	private func checkExpiry(_ approval: Approval) {
		lock.lock()
		let due = approval.status == "pending" && clock() >= approval.expiresAt
		lock.unlock()
		if due { resolve(approval, "expired", detail: "deadline") }
	}

	private func sweep() {
		lock.lock()
		let all = Array(approvals.values)
		lock.unlock()
		for approval in all { checkExpiry(approval) }
		let now = clock()
		lock.lock()
		approvals = approvals.filter { _, approval in
			guard let resolved = approval.resolvedAt else { return true }
			return now - resolved <= Self.retainResolved
		}
		lock.unlock()
	}

	/// pending → a terminal status; publishes `approval.resolved` once.
	@discardableResult
	private func resolve(_ approval: Approval, _ status: String, detail: String, reason: String? = nil) -> Bool {
		lock.lock()
		guard approval.status == "pending" else {
			lock.unlock()
			return false
		}
		approval.status = status
		approval.resolvedAt = clock()
		if let reason { approval.cancelReason = reason }
		lock.unlock()
		changed()
		log("approval.resolved", ["request_id": approval.requestID, "status": status, "detail": detail])
		publish("approval.resolved", ["request_id": approval.requestID, "status": status])
		push.notifyResolved(requestID: approval.requestID)
		return true
	}

	// MARK: HTTP side

	public func pending() -> [[String: Any]] {
		let now = clock()
		lock.lock()
		let items = approvals.values.filter { $0.status == "pending" && now < $0.expiresAt }.sorted {
			$0.createdAt < $1.createdAt
		}
		let out = items.map(\.summary)
		lock.unlock()
		return out
	}

	public var pendingCount: Int { pending().count }

	public func get(_ requestID: String) throws -> [String: Any] {
		lock.lock()
		let approval = approvals[requestID]
		lock.unlock()
		guard let approval else { throw APIError(404, "not_found", "no such approval") }
		checkExpiry(approval)
		lock.lock()
		defer { lock.unlock() }
		return approval.view
	}

	/// Applies a phone decision (§5.6). Returns the 200 body or throws the coded refusal.
	public func decide(_ requestID: String, device: DeviceRecord, decision: String, signature: Any?) throws
		-> [String: Any]
	{
		guard decision == "approve" || decision == "deny" else {
			throw APIError(400, "bad_request", "decision must be approve or deny")
		}
		// Only a device the owner confirmed may settle a request, either way. The registry is
		// re-read: a confirmation or a key change since the request was verified counts, and the
		// signature is checked against the approve key pinned now.
		guard let current = devices.get(device.deviceID), !current.isRevoked, current.approveConfirmed else {
			log("approval.unconfirmed", ["device": device.deviceID, "request_id": requestID])
			throw APIError(403, "device_unconfirmed", "confirm this iPhone on the Mac before it can decide")
		}
		return try settle(
			requestID, deciderID: current.deviceID, approvePubkey: current.approvePubkey, decision: decision,
			signature: signature, verify: !skipApprovePrecheck)
	}

	/// A decision from the Mac approval card (§8.1): the same broker round trip as a phone's, with
	/// the Mac approver's own key standing in for a device. It never consults the device registry:
	/// the Mac approver is not an account device, and a registry entry that happens to share its
	/// id can neither block nor impersonate it. Approve and deny are both verified against the
	/// Mac approve key here, before anything reaches the broker.
	public func decideFromMac(_ requestID: String, decision: String, signature: Any?) throws -> [String: Any] {
		guard decision == "approve" || decision == "deny" else {
			throw APIError(400, "bad_request", "decision must be approve or deny")
		}
		guard let mac = macApprover() else {
			throw APIError(409, "no_mac_approver", "this Mac has no approval card key")
		}
		return try settle(
			requestID, deciderID: mac.deviceID, approvePubkey: mac.approvePubkey, decision: decision,
			signature: signature, verify: true)
	}

	/// The shared tail of `decide` and `decideFromMac`: the caller has already established who is
	/// deciding and with which approve key.
	private func settle(
		_ requestID: String, deciderID: String, approvePubkey: String, decision: String, signature: Any?,
		verify: Bool
	) throws -> [String: Any] {
		lock.lock()
		let found = approvals[requestID]
		lock.unlock()
		guard let approval = found else { throw APIError(404, "not_found", "no such approval") }
		checkExpiry(approval)
		lock.lock()
		let status = approval.status
		lock.unlock()
		if status != "pending" {
			throw APIError(409, "approval_not_pending", "approval is \(status)", extra: ["status": status])
		}
		if clock() >= approval.expiresAt {
			resolve(approval, "expired", detail: "deadline")
			throw APIError(410, "approval_expired", "approval expired")
		}

		var message: [String: Any] = [
			"op": "approval.decision", "request_id": requestID, "decision": decision,
			"device_id": deciderID,
		]
		// Approve signs `WL1-APPROVE\n` + canonical, deny `WL1-DENY\n` + canonical, both with the
		// approve key: a captured one can never pass for the other.
		guard let signature = signature as? String, !signature.isEmpty else {
			throw APIError(422, "bad_signature", "\(decision) needs a signature")
		}
		if verify {
			let key = try? LinkPublicKey(x963Base64: approvePubkey)
			let der = Data(base64Encoded: signature) ?? Data()
			let verified =
				key.map {
					decision == "approve"
						? LinkSignatures.verifyApproval(
							canonical: approval.canonicalBytes, signature: der, approveKey: $0)
						: LinkSignatures.verifyDenial(canonical: approval.canonicalBytes, signature: der, approveKey: $0)
				} ?? false
			guard verified else {
				log(
					"approval.bad_signature",
					["device": deciderID, "request_id": requestID, "detail": "decision=\(decision)"])
				throw APIError(422, "bad_signature", "\(decision) signature does not verify")
			}
		}
		message["signature"] = signature

		lock.lock()
		if approval.status != "pending" {
			let current = approval.status
			lock.unlock()
			throw APIError(409, "approval_not_pending", "approval is \(current)", extra: ["status": current])
		}
		if approval.connection.isClosed {
			lock.unlock()
			throw APIError(503, "broker_unavailable", "broker connection is gone")
		}
		approval.status = decision == "approve" ? "approved" : "denied"
		approval.decidedBy = deciderID
		approval.decidedAt = clock()
		approval.resolvedAt = clock()
		message["decided_at"] = approval.decidedAt
		lock.unlock()
		do {
			try approval.connection.sendLine(message)
		} catch {
			lock.lock()
			approval.status = "cancelled"
			lock.unlock()
			publish("approval.resolved", ["request_id": requestID, "status": "cancelled"])
			push.notifyResolved(requestID: requestID)
			changed()
			throw APIError(503, "broker_unavailable", "broker connection is gone")
		}
		changed()
		log(
			"approval.decision",
			["device": deciderID, "request_id": requestID, "detail": "decision=\(decision)"])

		let got = approval.result.wait(timeout: .now() + Self.resultWait) == .success
		if got { approval.result.signal() }
		lock.lock()
		let finalStatus = approval.status
		let outcome = approval.brokerOutcome
		let cancelReason = approval.cancelReason
		lock.unlock()
		publish("approval.resolved", ["request_id": requestID, "status": finalStatus])
		push.notifyResolved(requestID: requestID)
		changed()
		if got && outcome == nil {
			if let cancelReason, cancelReason != "broker_eof" {
				throw APIError(
					409, "approval_not_pending", "the broker settled the approval first (\(cancelReason))",
					extra: ["status": finalStatus])
			}
			throw APIError(503, "broker_unavailable", "broker closed the connection without a result")
		}
		if !got {
			throw APIError(504, "broker_timeout", "no broker result in 3 s; poll GET /v1/approvals/\(requestID)")
		}
		return ["request_id": requestID, "status": finalStatus, "broker_outcome": outcome ?? NSNull()]
	}

}
