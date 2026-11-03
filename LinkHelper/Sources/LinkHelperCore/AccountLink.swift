import CryptoKit
import Foundation
import WhisperaLink

/// Account pairing on the Mac (step 11): the helper joins the owner's Whispera account once,
/// then keeps its DeviceRegistry in step with the account's iPhones — no pairing code.
///
/// - `connect` registers the Mac (`platform: macos`, the relay link key, a KEM record) with the
///   account bearer the app hands over, unless it already is, and persists the device id.
/// - The sync loop lists the account's devices over WL1 (`GET /v1/device/peers`) and pins every
///   active, well-formed iPhone under its account device id, unconfirmed. The backend supplies
///   both the keys and their fingerprints, so a listed phone is only a candidate: it gets no
///   link offer, STT key, push or API access until the owner compares its safety number with
///   the iPhone's screen and confirms it on the Mac. The number exists only after the phone
///   ran a committed exchange with this Mac (`sas_commit`, `sas_nonce`, `sas_reveal`; see
///   `SafetyNumber`), so a backend that substitutes keys gets one guess at matching the two
///   screens, not a search. A phone that never commits (an older Whispera) gets no number and
///   cannot be confirmed by one: its card says to update Whispera on the iPhone. A confirmed
///   phone gets a sealed `link_offer`, again only when what the offer says changes. A known
///   phone whose link, approve or agreement key changes is unconfirmed again
///   (`device.key_changed`). Phones
///   revoked or gone from the list are revoked here, so the HTTP API answers `auth_revoked`,
///   and nothing is sent to them.
/// - Relay messages are read by one `RelayMailbox` (long poll, open, ack): `unpaired` from a
///   verified iPhone of the account is acted on, and `api_request` / `api_cancel` from a pinned
///   iPhone go to the `RelayIngress`, which runs them through the LinkAPI (step 12).
/// - `confirmApprove` (the owner's Touch ID in the app, bound to the safety number the owner
///   saw) confirms a phone, sends it the link offer and then `approve_confirmed`.
/// - With an `AccountCircle`, a phone a linked Mac vouches for gets "Allow iPhone X, vouched by
///   Mac Y?" instead of its safety number; only the owner's Touch ID on that card here
///   (`confirmVouched`) confirms it. See `AccountCircle`.
///
/// The bearer is used for registration only and never stored.
public actor AccountLink {
	/// What a link offer advertises about this Mac, read when an offer is built.
	public struct OfferContext: Sendable, Equatable {
		public var baseURLs: [String]
		public var daemonPubkeyB64: String
		public var daemonFP: String
		public var macName: String
		/// Plain-LAN access is on: the offer says so (`allow_lan_http`), and the phone may use
		/// the Mac's plain `http://` LAN addresses directly.
		public var allowLANHTTP: Bool

		public init(
			baseURLs: [String], daemonPubkeyB64: String, daemonFP: String, macName: String, allowLANHTTP: Bool = false
		) {
			self.baseURLs = baseURLs
			self.daemonPubkeyB64 = daemonPubkeyB64
			self.daemonFP = daemonFP
			self.macName = macName
			self.allowLANHTTP = allowLANHTTP
		}
	}

	/// `account.json`.
	struct State: Codable, Equatable {
		var device_id: String
		var base_url: String
		var registered_at: Int
		/// Relay messages up to here were handled and acked.
		var cursor: Int64 = 0
		/// Per phone: a digest of the last offer sent (rotating STT key excluded).
		var offers: [String: String] = [:]
		/// Phones that sent `unpaired`: never pinned again under this id.
		var unpaired: [String] = []
		var last_sync_at: Int?
		var last_error: String?
		/// Devices revoked here whose backend revoke has not gone through yet: retried with the
		/// next account bearer the app hands over (`connect`), since the bearer is never stored.
		var pending_revokes: [String]?
		/// Per phone: its latest safety-number attempt (`SASResponder`). Optional so older files load.
		var sas: [String: SASResponder]?
		/// Per phone: when its recent attempts started (Unix seconds), to cap them.
		var sas_starts: [String: [Int]]?
	}

	/// The account side of revoking a device here (`devices.revoke`).
	public struct AccountRevoke: Sendable, Equatable {
		/// The backend revoked it (or no longer lists it for this account).
		public var ok: Bool
		public var code: String?
		public var message: String?
		/// Kept to retry with the next bearer.
		public var queued: Bool

		public var json: [String: Any] {
			var out: [String: Any] = ["ok": ok]
			if let code { out["error"] = ["code": code, "message": message ?? code] }
			if queued { out["queued"] = true }
			return out
		}
	}

	/// New safety-number attempts accepted per phone per hour. Each one is a fresh 2^-40 guess
	/// for a backend that substitutes keys, and changes the number the card shows.
	static let sasAttemptsPerHour = 10
	/// A pending phone that has not committed this long after it was pinned is taken for one that
	/// predates the exchange: its card says to update Whispera on the iPhone.
	static let sasUpdateHintAfter = 60

	public struct SyncReport: Sendable, Equatable {
		public var pinned: [String] = []
		public var offered: [String] = []
		public var dropped: [String] = []
		public var untrusted: [String] = []
		/// Known phones whose keys changed: unconfirmed again.
		public var keyChanged: [String] = []
		/// Unconfirmed phones a linked Mac vouches for: their card asks for Touch ID, not a number.
		public var vouched: [String] = []
	}

	private let paths: HelperConfig.Paths
	private let devices: DeviceRegistry
	private let push: SwitchablePush
	private let transport: LinkTransport
	private let log: OpsLog
	private let offerContext: @Sendable () -> OfferContext
	private let clock: @Sendable () -> Int
	private let pollWait: Int
	private let ingress: RelayIngress?
	private let pushSealer: PushSealer
	private let approvalFallback: TimeInterval
	/// Drops relay messages delivered twice (persisted across launches).
	nonisolated let replayGuard: RelayReplayGuard
	/// Zero-touch linking through devices the owner already trusts; nil turns it off.
	public let circle: AccountCircle?
	private var state: State?
	private var snapshot: AccountDevices?
	private var mailbox: RelayMailbox?
	private var loop: Task<Void, Never>?
	private var tail: Task<Void, Never>?
	private var status = "signed_out"

	public init(
		paths: HelperConfig.Paths, devices: DeviceRegistry, push: SwitchablePush,
		transport: LinkTransport = URLSessionLinkTransport(), pollWait: Int = 25, log: OpsLog = .null,
		ingress: RelayIngress? = nil, pushSealer: PushSealer = PushSealer(), approvalFallback: TimeInterval = 20,
		circle: AccountCircle? = nil,
		clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
		offerContext: @escaping @Sendable () -> OfferContext
	) {
		self.paths = paths
		self.devices = devices
		self.push = push
		self.transport = transport
		self.pollWait = pollWait
		self.ingress = ingress
		self.pushSealer = pushSealer
		self.approvalFallback = approvalFallback
		self.circle = circle
		self.log = log
		self.clock = clock
		self.offerContext = offerContext
		replayGuard = RelayReplayGuard(path: paths.relaySeen, clock: { Int64(clock()) })
		if let data = FileManager.default.contents(atPath: paths.accountState),
			let loaded = try? JSONDecoder().decode(State.self, from: data),
			LinkCrypto.isValidDeviceID(loaded.device_id)
		{
			state = loaded
			status = "registered"
		}
		circle?.setIdentity(circleIdentity(state?.device_id))
	}

	// MARK: Public surface (XPC, admin socket)

	/// The Mac's account device id, when registered.
	public var deviceID: String? { state?.device_id }

	public func statusObject() -> [String: Any] {
		[
			"ok": true, "status": status, "device_id": state?.device_id ?? NSNull(),
			"base_url": state?.base_url ?? NSNull(), "last_sync_at": state?.last_sync_at ?? NSNull(),
			"last_error": state?.last_error ?? NSNull(), "syncing": loop != nil,
			"phones": devices.active().filter { $0.origin == .account }.map(\.deviceID),
			"pending_confirmations": devices.pendingApproveConfirmations().count,
			"key_changed": devices.pendingApproveConfirmations().filter { $0.keyChangedAt != nil }.map(\.deviceID),
			"circle": circle?.statusObject() ?? NSNull(),
		]
	}

	/// Joins the account behind `bearer` at `backendURL` (registering this Mac unless it already
	/// is a live device of that account there), then starts syncing.
	public func connect(bearer: String, backendURL: URL) async throws -> [String: Any] {
		guard ["http", "https"].contains(backendURL.scheme?.lowercased() ?? ""), backendURL.host != nil else {
			throw APIError(400, "bad_request", "backend_url must be an http(s) URL")
		}
		let bearer = bearer.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bearer.isEmpty else { throw APIError(400, "bad_request", "bearer is required") }
		try await serialized { try await self.connectLocked(bearer: bearer, backendURL: backendURL) }
		startLoop()
		return statusObject()
	}

	/// Leaves the account on this Mac: tells each pinned phone it is unpaired (best effort),
	/// revokes the account pins, forgets the registration. The app revokes the device itself.
	public func disconnect() async -> [String: Any] {
		loop?.cancel()
		loop = nil
		stopMailbox()
		_ = try? await serialized { await self.disconnectLocked() }
		return statusObject()
	}

	/// One sync now (peers + messages without waiting).
	public func syncNow() async throws -> SyncReport {
		try await serialized {
			let report = try await self.syncPeersLocked()
			try await self.pollMessagesLocked(wait: 0)
			return report
		}
	}

	/// `deviceID` (an account phone) was revoked in the registry here: withdraw this Mac's vouch
	/// for it at once, and revoke it on the account backend too, so the relay and the account's
	/// other Macs drop it. That needs the account bearer (`bearer`, used once and never stored);
	/// without one, or when the backend call fails, the revoke is queued and retried with the
	/// next bearer `connect` gets. The local revoke stands either way.
	public func revokeInAccount(_ deviceID: String, bearer: String?) async -> AccountRevoke {
		circle?.withdraw(deviceID)
		let result = try? await serialized { await self.revokeInAccountLocked(deviceID, bearer: bearer) }
		return result ?? AccountRevoke(ok: false, code: "internal", message: "account revoke did not run", queued: false)
	}

	/// The confirm cards. One a linked Mac vouches for (with exactly the keys pinned here) says
	/// so: `vouched_by` / `vouched_by_name`; the app then asks "Allow iPhone X, vouched by Mac Y?"
	/// with Touch ID instead of the safety number. The vouch confirms nothing by itself.
	public func pendingConfirmations() -> [[String: Any]] {
		let macLink = macLinkKey()
		let vouches = vouchesForPending()
		let names = circle?.vouchHints() ?? [:]
		return devices.pendingApproveConfirmations().map { record in
			var card = confirmationObject(record, macLink: macLink)
			if let vouch = vouches[record.deviceID] {
				card["vouched_by"] = vouch.voucher_id
				card["vouched_by_name"] = names[record.deviceID] ?? NSNull()
			}
			return card
		}
	}

	/// Fresh vouches from linked Macs covering a pending phone as it is pinned here.
	private func vouchesForPending() -> [String: DeviceVouch] {
		guard let circle, let snapshot else { return [:] }
		let accepted = circle.accepted(account: snapshot)
		return accepted.filter { id, _ in
			guard let record = devices.get(id), !record.approveConfirmed, let phone = snapshot.phones.first(where: { $0.id == id })
			else { return false }
			return Self.keysMatch(record, phone)
		}
	}

	/// "Allow iPhone X, vouched by Mac Y?": the owner's Touch ID in the app, after seeing the
	/// phone's `linkFingerprint` and the voucher. Refused (409) unless a fresh vouch from a linked
	/// Mac still covers the phone's keys as pinned here and the fingerprint is the one shown. The
	/// evidence (`vouch`, the voucher) is stored with the confirmation. Then as `confirmApprove`.
	public func confirmVouched(_ deviceID: String, linkFingerprint: String, vouchedBy: String) async throws -> [String: Any] {
		_ = try? await serialized { try await self.syncPeersLocked() }
		guard let vouch = vouchesForPending()[deviceID], vouch.voucher_id == vouchedBy, let circle, let snapshot else {
			throw APIError(409, "keys_changed", "no linked Mac vouches for this iPhone as it is now; compare the safety number")
		}
		let record: DeviceRecord?
		do {
			// Checked again under the registry lock: the vouch is still fresh, from a Mac still
			// linked here, the one the card named, for exactly these keys.
			record = try devices.confirmApprove(deviceID, evidence: "vouch", vouchedBy: vouch.voucher_id) { current in
				guard let now = circle.accepted(account: snapshot)[deviceID], now.voucher_id == vouchedBy else { return false }
				return (try? LinkPublicKey(x963Base64: current.linkPubkey).displayFingerprint) == linkFingerprint
					&& current.linkPubkey == now.subject_link_pubkey && current.approvePubkey == now.subject_approve_pubkey
					&& current.kemPubkey == now.subject_kem_pubkey
			}
		} catch let error as APIError {
			log("device.confirm_refused", ["device": deviceID, "detail": error.code])
			throw error
		}
		guard let record else { throw APIError(404, "not_found", "no such active device") }
		log("device.approve_confirmed", ["device": deviceID, "detail": "vouched by \(vouch.voucher_id)"])
		var sent = false
		if record.origin == .account, state != nil {
			sent = (try? await serialized { try await self.sendConfirmedLocked(deviceID) }) ?? false
		}
		return ["ok": true, "device": record.publicJSON, "notified": sent]
	}

	/// This Mac's account link key (the one the phone lists for it), when registered.
	nonisolated func macLinkKey() -> LinkPublicKey? {
		guard let pem = try? String(contentsOfFile: paths.relayKey, encoding: .utf8),
			let key = try? SoftwareSigningKey(pkcs8PEM: pem)
		else { return nil }
		return key.publicKey
	}

	/// The number the owner compares with the iPhone's screen: only from an exchange the phone
	/// finished with this Mac for exactly the keys pinned here.
	func safetyNumber(_ record: DeviceRecord, macLink: LinkPublicKey?) -> String? {
		state?.sas?[record.deviceID]?.number(
			phoneLink: record.linkPubkey, phoneApprove: record.approvePubkey, macLink: macLink)
	}

	/// What the card says about the number: `ready`, `waiting` (the exchange is under way or not
	/// started yet), `failed` (the phone's reveal did not open its commitment, or named other
	/// keys: it has to start over) or `update_required` (the phone never started one).
	func safetyNumberStatus(_ record: DeviceRecord, macLink: LinkPublicKey?, now: Int? = nil) -> String {
		if safetyNumber(record, macLink: macLink) != nil { return "ready" }
		if let attempt = state?.sas?[record.deviceID] {
			return attempt.stage == .failed ? "failed" : "waiting"
		}
		let since = max(record.createdAt, record.keyChangedAt ?? 0)
		return (now ?? clock()) - since >= Self.sasUpdateHintAfter ? "update_required" : "waiting"
	}

	static func normalizedSafetyNumber(_ text: String) -> String {
		text.filter(\.isNumber)
	}

	/// The owner confirmed `deviceID` (Touch ID in the app) after comparing `safetyNumber` with
	/// the iPhone. The number is recomputed from the record as it is now; any difference (keys
	/// changed since the card was shown) refuses with 409 `keys_changed`. Then, for an account
	/// phone, sends it a link offer with a fresh STT key and `approve_confirmed`.
	public func confirmApprove(_ deviceID: String, safetyNumber: String) async throws -> [String: Any] {
		let shown = Self.normalizedSafetyNumber(safetyNumber)
		guard shown.count == 12 else {
			throw APIError(400, "bad_request", "safety_number must be the 12 digits the owner compared")
		}
		let macLink = macLinkKey()
		let attempts = state?.sas ?? [:]
		if let pending = devices.get(deviceID), !pending.isRevoked, attempts[deviceID] == nil {
			// No committed exchange at all: an older iPhone, or one that has not started it. Never
			// fall back to a number computed from the listed keys alone.
			log("device.confirm_refused", ["device": deviceID, "detail": "no_safety_number"])
			throw APIError(
				409, "peer_update_required",
				"no safety number from this iPhone yet; open Whispera on it, and update it if this persists")
		}
		let record: DeviceRecord?
		do {
			record = try devices.confirmApprove(deviceID) { current in
				guard
					let expected = attempts[current.deviceID]?.number(
						phoneLink: current.linkPubkey, phoneApprove: current.approvePubkey, macLink: macLink)
				else { return false }
				return Self.normalizedSafetyNumber(expected) == shown
			}
		} catch let error as APIError {
			log("device.confirm_refused", ["device": deviceID, "detail": error.code])
			throw error
		}
		guard let record else { throw APIError(404, "not_found", "no such active device") }
		log("device.approve_confirmed", ["device": deviceID])
		var sent = false
		if record.origin == .account, state != nil {
			sent = (try? await serialized { try await self.sendConfirmedLocked(deviceID) }) ?? false
		}
		return ["ok": true, "device": record.publicJSON, "notified": sent]
	}

	/// Starts the background sync when registered. Idempotent.
	public func start() {
		guard state != nil else { return }
		activatePush()
		startLoop()
	}

	public func stop() {
		loop?.cancel()
		loop = nil
		circle?.stop()
		stopMailbox()
	}

	// MARK: Linking Macs

	/// Macs that proved themselves on the tailnet and wait for the owner's "Link" here.
	public func pendingLinks() -> [[String: Any]] {
		circle?.pendingLinks() ?? []
	}

	/// Macs that answered from another node than the one they are bound to (a "Relink" row each).
	public func movedMacs() -> [[String: Any]] {
		circle?.movedMacs() ?? []
	}

	/// Macs linked here (an "Unlink" row each).
	public func linkedMacs() -> [[String: Any]] {
		circle?.linkedMacs() ?? []
	}

	/// The owner's answer to a "Link this Mac?" card: `approve` (after Touch ID, bound to the
	/// tailnet name and link fingerprint the card showed) or `decline` (also "Unlink"). Then
	/// syncs, so what the approval unlocks (phones the Mac vouches for, this Mac's vouch for it)
	/// applies now.
	public func decideLink(
		_ deviceID: String, approve: Bool, tailnetName: String, linkFingerprint: String = "", name: String = "",
		nodeID: String = "", relink: Bool = false
	) async throws -> [String: Any] {
		guard let circle else { throw APIError(404, "not_found", "linking Macs is off on this helper") }
		if relink {
			try circle.relink(deviceID)
			await circle.probeNow(force: true)
		} else if approve {
			try circle.approveLink(
				deviceID, tailnetName: tailnetName, linkFingerprint: linkFingerprint, name: name, nodeID: nodeID)
			await circle.probeNow()
		} else {
			try circle.declineLink(deviceID)
		}
		let report = try? await serialized { try await self.syncPeersLocked() }
		return ["ok": true, "vouched": report?.vouched ?? []]
	}

	/// A probe learned something: apply it without waiting for the next round.
	private func syncSoon() {
		Task { _ = try? await self.serialized { try await self.syncPeersLocked() } }
	}

	private func startCircle() {
		guard let circle, pollWait >= 0 else { return }
		circle.start { [weak self] in Task { await self?.syncSoon() } }
	}

	func confirmationObject(_ record: DeviceRecord, macLink: LinkPublicKey?) -> [String: Any] {
		let fingerprint =
			(try? LinkPublicKey(x963Base64: record.approvePubkey).displayFingerprint) ?? record.approveFP
		let linkFingerprint = (try? LinkPublicKey(x963Base64: record.linkPubkey).displayFingerprint) ?? record.linkFP
		return [
			"device_id": record.deviceID, "name": record.name, "platform": "ios", "approve_fp": record.approveFP,
			"fingerprint": fingerprint, "link_fingerprint": linkFingerprint, "created_at": record.createdAt,
			"safety_number": safetyNumber(record, macLink: macLink) ?? NSNull(),
			"sas_status": safetyNumberStatus(record, macLink: macLink),
			"key_changed": record.keyChangedAt != nil, "key_changed_at": record.keyChangedAt ?? NSNull(),
		]
	}

	/// Whether the account still lists `phone` with exactly the keys pinned in `record`.
	static func keysMatch(_ record: DeviceRecord, _ phone: TrustedDevice) -> Bool {
		record.linkPubkey == phone.linkKey.x963Base64 && record.approvePubkey == phone.approveKey?.x963Base64
			&& record.kemPubkey == phone.agreementKey.x963Base64
	}

	/// The listed phones that are pinned here, confirmed by the owner, with unchanged keys: the
	/// only ones pushes are sealed to.
	private func confirmedPhones(_ account: AccountDevices) -> [TrustedDevice] {
		account.phones.filter { phone in
			guard let record = devices.get(phone.id), !record.isRevoked, record.approveConfirmed else { return false }
			return Self.keysMatch(record, phone)
		}
	}

	// MARK: Serialisation

	/// Runs `operation` after every earlier one finished: the loop, an admin `account.sync` and
	/// an XPC confirm never interleave their sends.
	private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		let previous = tail
		let task = Task<T, Error> {
			await previous?.value
			return try await operation()
		}
		tail = Task { _ = try? await task.value }
		return try await task.value
	}

	private func startLoop() {
		// A negative wait turns the background loop off (tests drive `syncNow` themselves).
		guard loop == nil, state != nil, pollWait >= 0 else { return }
		startCircle()
		// The mailbox long-polls on its own task, so a relayed request is served as soon as it
		// lands; this loop only keeps the pinned phones in step with the account.
		let interval = UInt64(max(pollWait, 1))
		loop = Task { [weak self] in
			var backoff: UInt64 = 1
			while !Task.isCancelled {
				guard let self else { return }
				do {
					try await self.serialized {
						_ = try await self.syncPeersLocked()
					}
					backoff = 1
					try await self.startMailbox()
					try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
				} catch is CancellationError {
					return
				} catch {
					let stopped = await self.recordFailure(error)
					if stopped { return }
					try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
					backoff = min(backoff * 2, 60)
				}
			}
		}
	}

	/// Notes a failed round; returns true when the loop should stop (this Mac was revoked).
	private func recordFailure(_ error: Error) -> Bool {
		let code = (error as? LinkError)?.code ?? (error as? APIError)?.code ?? "\(type(of: error))"
		state?.last_error = code
		saveState()
		log("account.sync_error", ["detail": code])
		if ["auth_revoked", "auth_unknown_device"].contains(code) {
			status = "revoked"
			loop = nil
			stopMailbox()
			return true
		}
		return false
	}

	// MARK: Registration

	private func connectLocked(bearer: String, backendURL: URL) async throws {
		let base = Self.trimmed(backendURL.absoluteString)
		if let state, state.base_url == base {
			let listed = try await RelayClient.devices(
				baseURL: backendURL, accountToken: bearer, transport: transport)
			if listed.contains(where: { $0.device_id == state.device_id && !$0.isRevoked }) {
				status = "registered"
				activatePush()
				log("account.connected", ["device": state.device_id, "detail": "already registered"])
				await flushPendingRevokes(bearer: bearer)
				return
			}
			// Signed into another account, or this Mac was revoked: start over with new keys.
			log("account.reregister", ["device": state.device_id])
			dropAccountPins(reason: "account_changed")
			circle?.reset()
			stopMailbox()
		}
		let linkKey = SoftwareSigningKey()
		let kemKey = P256.KeyAgreement.PrivateKey()
		let name = offerContext().macName
		let device = try await AccountDeviceRegistration.register(
			baseURL: backendURL, accountToken: bearer, name: name.isEmpty ? "Mac" : name, platform: .macos,
			linkKey: linkKey, agreementKey: LinkPublicKey(kemKey.publicKey), transport: transport)
		try FileStore.writeAtomic(Data((linkKey.privateKey.pemRepresentation + "\n").utf8), to: paths.relayKey)
		try FileStore.writeAtomic(Data((kemKey.pemRepresentation + "\n").utf8), to: paths.relayKEMKey)
		state = State(device_id: device.device_id, base_url: base, registered_at: clock())
		snapshot = nil
		status = "registered"
		saveState()
		updateCircleIdentity()
		activatePush()
		log("account.registered", ["device": device.device_id])
	}

	private func disconnectLocked() async {
		if let client = try? client(), let snapshot {
			for record in devices.active() where record.origin == .account {
				guard let peer = snapshot.peer(record.deviceID) else { continue }
				_ = try? await client.send(.unpaired(deviceID: record.deviceID), to: peer)
			}
		}
		dropAccountPins(reason: "signed_out")
		circle?.reset()
		state = nil
		snapshot = nil
		status = "signed_out"
		try? FileManager.default.removeItem(atPath: paths.accountState)
		push.replace(with: UnconfiguredPush())
		pushSealer.configure(macID: nil, agreementKey: nil, macName: "")
		log("account.disconnected")
	}

	private func revokeInAccountLocked(_ deviceID: String, bearer: String?) async -> AccountRevoke {
		guard state != nil else {
			return AccountRevoke(
				ok: false, code: "not_registered", message: "this Mac has not joined an account", queued: false)
		}
		state?.offers[deviceID] = nil
		var pending = state?.pending_revokes ?? []
		if !pending.contains(deviceID) { pending.append(deviceID) }
		state?.pending_revokes = Array(pending.suffix(256))
		saveState()
		let bearer = (bearer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bearer.isEmpty else {
			log("account.revoke_queued", ["device": deviceID, "detail": "no bearer"])
			return AccountRevoke(
				ok: false, code: "bearer_required",
				message: "revoked on this Mac; the account revoke runs when Whispera next signs the helper in",
				queued: true)
		}
		return await backendRevoke(deviceID, bearer: bearer)
	}

	/// One backend revoke; on success (or when the account no longer has the device) it leaves
	/// the queue.
	private func backendRevoke(_ deviceID: String, bearer: String) async -> AccountRevoke {
		guard let base = state.flatMap({ URL(string: $0.base_url) }) else {
			return AccountRevoke(ok: false, code: "not_registered", message: "this Mac has not joined an account", queued: false)
		}
		do {
			try await RelayClient.revoke(baseURL: base, accountToken: bearer, deviceID: deviceID, transport: transport)
		} catch {
			let code = (error as? LinkError)?.code ?? (error as? APIError)?.code ?? "\(type(of: error))"
			if code != "not_found" {
				log("account.revoke_failed", ["device": deviceID, "detail": code])
				return AccountRevoke(
					ok: false, code: code, message: "revoked on this Mac; the account revoke failed and will be retried",
					queued: true)
			}
		}
		state?.pending_revokes?.removeAll { $0 == deviceID }
		if state?.pending_revokes?.isEmpty == true { state?.pending_revokes = nil }
		saveState()
		log("account.revoked_device", ["device": deviceID])
		return AccountRevoke(ok: true, code: nil, message: nil, queued: false)
	}

	/// Retries queued backend revokes with a fresh bearer (best effort).
	private func flushPendingRevokes(bearer: String) async {
		for id in state?.pending_revokes ?? [] { _ = await backendRevoke(id, bearer: bearer) }
	}

	private func dropAccountPins(reason: String) {
		for record in devices.active() where record.origin == .account {
			devices.revoke(record.deviceID)
			log("device.revoked", ["device": record.deviceID, "detail": reason])
		}
	}

	/// The circle signs vouches and peer proofs as this Mac's account device.
	private nonisolated func circleIdentity(_ deviceID: String?) -> AccountCircle.Identity? {
		guard let deviceID, let pem = try? String(contentsOfFile: paths.relayKey, encoding: .utf8),
			let key = try? SoftwareSigningKey(pkcs8PEM: pem)
		else { return nil }
		return AccountCircle.Identity(deviceID: deviceID, key: key)
	}

	private func updateCircleIdentity() {
		circle?.setIdentity(circleIdentity(state?.device_id))
	}

	private func activatePush() {
		guard let client = try? client() else { return }
		pushSealer.configure(
			macID: state?.device_id, agreementKey: try? agreementKey(), macName: offerContext().macName)
		push.replace(
			with: RelayPush(
				client: client, sealer: pushSealer, fallbackAfter: approvalFallback, log: log, transport: transport))
	}

	private func client() throws -> RelayClient {
		guard let state, let base = URL(string: state.base_url) else {
			throw APIError(409, "not_registered", "this Mac has not joined an account")
		}
		let pem = try String(contentsOfFile: paths.relayKey, encoding: .utf8)
		return RelayClient(
			baseURL: base, deviceID: state.device_id, linkKey: try SoftwareSigningKey(pkcs8PEM: pem),
			transport: transport)
	}

	private func agreementKey() throws -> SoftwareAgreementKey {
		let pem = try String(contentsOfFile: paths.relayKEMKey, encoding: .utf8)
		return SoftwareAgreementKey(try P256.KeyAgreement.PrivateKey(pemRepresentation: pem))
	}

	private func saveState() {
		guard let state else { return }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		if let data = try? encoder.encode(state) { try? FileStore.writeAtomic(data, to: paths.accountState) }
	}

	// MARK: Sync

	private func syncPeersLocked() async throws -> SyncReport {
		let client = try client()
		guard let myID = state?.device_id else { throw APIError(409, "not_registered", "not registered") }
		let listed = try await client.peers()
		let account = AccountDevices(classifying: listed, selfID: myID)
		snapshot = account
		var report = SyncReport()
		report.untrusted = account.untrusted.map(\.id)
		let unpaired = Set(state?.unpaired ?? [])
		var keep: Set<String> = []
		let context = offerContext()
		var vouches: [String: DeviceVouch] = [:]
		if let circle {
			let waiting = account.phones.contains { devices.get($0.id)?.approveConfirmed != true }
			circle.update(account: account, needsTrust: waiting)
			vouches = circle.accepted(account: account)
		}

		for phone in account.phones where !unpaired.contains(phone.id) {
			guard let approve = phone.approveKey else {
				log("account.skip", ["device": phone.id, "detail": "no approve key"])
				continue
			}
			let pinned: DeviceRegistry.PinResult
			do {
				pinned = try devices.pinAccountDevice(
					deviceID: phone.id, name: phone.name, link: phone.linkKey, approve: approve,
					kem: phone.agreementKey)
			} catch {
				log("account.skip", ["device": phone.id, "detail": "pin failed"])
				continue
			}
			guard !pinned.record.isRevoked else { continue }
			keep.insert(phone.id)
			if pinned.isNew {
				report.pinned.append(phone.id)
				log("device.pinned", ["device": phone.id, "detail": "account unconfirmed"])
			}
			if pinned.keyChanged {
				report.keyChanged.append(phone.id)
				state?.offers[phone.id] = nil
				log("device.key_changed", ["device": phone.id, "detail": "unconfirmed until the owner confirms again"])
			}
			let record = pinned.record
			// Nothing goes to a phone the owner has not confirmed: no offer, no STT key.
			guard record.approveConfirmed else { continue }
			let digest = Self.offerDigest(context, approveConfirmed: record.approveConfirmed)
			if state?.offers[phone.id] != digest {
				if try await sendOffer(client, to: phone, record: record, context: context, myID: myID) {
					state?.offers[phone.id] = digest
					report.offered.append(phone.id)
				}
			}
		}

		for record in devices.active() where record.origin == .account && !keep.contains(record.deviceID) {
			devices.revoke(record.deviceID)
			state?.offers[record.deviceID] = nil
			report.dropped.append(record.deviceID)
			let why = account.revokedIDs.contains(record.deviceID) ? "revoked in account" : "not in account"
			log("device.revoked", ["device": record.deviceID, "detail": why])
		}
		report.vouched = account.phones.filter { phone in
			guard vouches[phone.id]?.covers(phone) == true, let record = devices.get(phone.id) else { return false }
			return !record.approveConfirmed && Self.keysMatch(record, phone)
		}.map(\.id)
		let confirmed = confirmedPhones(account)
		pushSealer.setPhones(confirmed)
		// Only phones whose safety number was compared here are vouched for onward.
		circle?.publish(
			account: account,
			ownPhones: confirmed.filter { devices.get($0.id)?.confirmEvidence == "safety_number" })
		state?.last_sync_at = clock()
		state?.last_error = nil
		status = "registered"
		saveState()
		return report
	}

	/// Sends a fresh offer (with a newly minted STT key whose hash replaces the old one).
	private func sendOffer(
		_ client: RelayClient, to phone: TrustedDevice, record: DeviceRecord, context: OfferContext, myID: String
	) async throws -> Bool {
		let sttKey = "wlk_" + LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		let offer = LinkOffer(
			helper_device_id: myID, base_urls: context.baseURLs, daemon_pubkey: context.daemonPubkeyB64,
			daemon_fp: context.daemonFP, stt_key: sttKey,
			stt_base_url: context.baseURLs.first.map { Self.trimmed($0) + "/v1" },
			mac_name: context.macName, approve_confirmed: record.approveConfirmed,
			allow_lan_http: context.allowLANHTTP ? true : nil, issued_at: Int64(Date().timeIntervalSince1970))
		do {
			try devices.setSTTKeySHA256(phone.id, LinkCrypto.sha256Hex(Data(sttKey.utf8)))
			try await client.send(.linkOffer(offer), to: phone)
		} catch let error as LinkError {
			log("account.offer_failed", ["device": phone.id, "detail": error.code])
			if ["auth_revoked", "auth_unknown_device"].contains(error.code) { throw error }
			return false
		}
		log("account.offer_sent", ["device": phone.id, "detail": "urls=\(context.baseURLs.count)"])
		return true
	}

	/// After the owner's confirmation: the link offer (fresh STT key), then `approve_confirmed`,
	/// both only to the listed phone whose keys are the ones confirmed.
	private func sendConfirmedLocked(_ deviceID: String) async throws -> Bool {
		let client = try client()
		guard let myID = state?.device_id else { return false }
		_ = try await syncPeersLocked()
		guard let peer = snapshot?.phones.first(where: { $0.id == deviceID }), let record = devices.get(deviceID),
			record.approveConfirmed, !record.isRevoked, Self.keysMatch(record, peer)
		else { return false }
		let context = offerContext()
		let digest = Self.offerDigest(context, approveConfirmed: true)
		if state?.offers[deviceID] != digest {
			guard try await sendOffer(client, to: peer, record: record, context: context, myID: myID) else {
				return false
			}
			state?.offers[deviceID] = digest
		}
		try await client.send(.approveConfirmed(deviceID: deviceID), to: peer)
		saveState()
		log("account.approve_confirmed_sent", ["device": deviceID])
		return true
	}

	// MARK: Mailbox

	/// The relay inbox: one mailbox per registration, its cursor saved in `account.json`.
	private func ensureMailbox() async throws -> RelayMailbox {
		if let mailbox { return mailbox }
		guard let myID = state?.device_id else { throw APIError(409, "not_registered", "not registered") }
		let box = RelayMailbox(
			client: try client(), agreementKey: try agreementKey(),
			devices: { [weak self] refresh in
				guard let self else { throw CancellationError() }
				return try await self.accountDevices(refresh: refresh)
			},
			wait: max(pollWait, 0), idleDelay: pollWait > 0 ? 0 : 1,
			loadCursor: { [weak self] in await self?.cursor ?? 0 },
			saveCursor: { [weak self] in await self?.saveCursor($0) },
			handler: { [weak self] received in await self?.handle(received) })
		let log = self.log
		await box.setEventObserver { event in
			switch event {
			case .rejected(_, let from, let error):
				log("account.message_rejected", ["device": from, "detail": String(error.prefix(80))])
			case .unroutedResponse(_, let from):
				log("account.message_ignored", ["device": from, "detail": "api_response"])
			case .fetchFailed(let detail):
				log("account.poll_error", ["detail": String(detail.prefix(80))])
			case .refreshedDevices(let sender):
				log("account.peers_refresh", ["device": sender])
			}
		}
		mailbox = box
		log.debug("account.mailbox", ["device": myID])
		return box
	}

	private func startMailbox() async throws {
		try await ensureMailbox().start()
	}

	private func stopMailbox() {
		guard let box = mailbox else { return }
		mailbox = nil
		Task { await box.stop() }
	}

	private var cursor: Int64 { state?.cursor ?? 0 }

	private func saveCursor(_ value: Int64) {
		replayGuard.flush()
		guard state != nil, value > (state?.cursor ?? 0) else { return }
		state?.cursor = value
		saveState()
	}

	/// The mailbox's view of the account: the last peer list, re-fetched when it meets a
	/// sender it does not know (pinning stays with the sync loop).
	private func accountDevices(refresh: Bool) async throws -> AccountDevices {
		if !refresh, let snapshot { return snapshot }
		let listed = try await client().peers()
		let account = AccountDevices(classifying: listed, selfID: state?.device_id)
		snapshot = account
		pushSealer.setPhones(confirmedPhones(account))
		return account
	}

	private func pollMessagesLocked(wait: Int) async throws {
		_ = try await ensureMailbox().pumpOnce(wait: wait)
	}

	private func handle(_ received: ReceivedLinkMessage) async {
		let sender = received.sender
		guard replayGuard.firstSeen(sender: sender.id, messageID: received.messageID, createdAt: received.createdAt) else {
			log("account.message_ignored", ["device": sender.id, "detail": "replayed \(received.message.type)"])
			return
		}
		switch received.message {
		case .unpaired(let id):
			replayGuard.flush()
			guard sender.platform == .ios, id == sender.id || id == state?.device_id else {
				log("account.message_ignored", ["device": sender.id, "detail": "unpaired for another device"])
				return
			}
			if let record = devices.get(sender.id), record.origin == .account {
				// Bound to the pairing as it is here: signed with the key pinned now, and sealed
				// after that key was pinned (an older `unpaired` is from an earlier pairing).
				let pinnedAt = Int64(record.keyChangedAt ?? record.createdAt)
				guard record.linkPubkey == sender.linkKey.x963Base64,
					received.createdAt == 0 || received.createdAt + SealedEnvelope.defaultFutureSkew >= pinnedAt
				else {
					log("account.message_ignored", ["device": sender.id, "detail": "unpaired from an earlier pairing"])
					return
				}
				devices.revoke(sender.id)
			}
			if state?.unpaired.contains(sender.id) == false { state?.unpaired.append(sender.id) }
			state?.offers[sender.id] = nil
			state?.sas?[sender.id] = nil
			saveState()
			log("device.revoked", ["device": sender.id, "detail": "phone unpaired"])
		case .apiRequest(let request):
			guard let ingress, let client = try? client() else {
				log("account.message_ignored", ["device": sender.id, "detail": "api_request"])
				return
			}
			ingress.accept(request, sender: sender) { messages in
				try await Self.sendFrames(messages, to: sender, client: client)
			}
		case .apiCancel(let id):
			ingress?.cancel(id: id, sender: sender.id)
		case .sasCommit(let commit):
			await startSafetyNumber(commit, from: sender)
		case .sasReveal(let reveal):
			finishSafetyNumber(reveal, from: sender)
		case .linkOffer, .approveConfirmed, .apiResponse, .sasNonce:
			log("account.message_ignored", ["device": sender.id, "detail": received.message.type])
		}
	}

	// MARK: Safety number

	/// `sas_commit`: records the phone's commitment as its new attempt (replacing any earlier
	/// one), then answers with this Mac's nonce. The nonce leaves only after the commitment is
	/// stored, and a commitment is never accepted twice for the same attempt.
	private func startSafetyNumber(_ commit: SASCommit, from sender: TrustedDevice) async {
		guard sender.platform == .ios, sender.approveKey != nil, let myState = state, !myState.unpaired.contains(sender.id),
			let macLink = macLinkKey(), let client = try? client()
		else {
			log("account.sas_refused", ["device": sender.id, "detail": "not an account iPhone"])
			return
		}
		if myState.sas?[sender.id]?.attempt == commit.attempt {
			log("account.sas_refused", ["device": sender.id, "detail": "attempt already used"])
			return
		}
		let now = clock()
		var starts = (myState.sas_starts?[sender.id] ?? []).filter { now - $0 < 3600 }
		guard starts.count < Self.sasAttemptsPerHour else {
			log("account.sas_refused", ["device": sender.id, "detail": "too many attempts"])
			return
		}
		let attempt: SASResponder
		do {
			attempt = try SASResponder(commit: commit, startedAt: now)
		} catch {
			log("account.sas_refused", ["device": sender.id, "detail": "\(error)"])
			return
		}
		starts.append(now)
		var updated = myState
		updated.sas_starts = (myState.sas_starts ?? [:]).merging([sender.id: starts]) { $1 }
		updated.sas = (myState.sas ?? [:]).merging([sender.id: attempt]) { $1 }
		state = updated
		saveState()
		log("account.sas_started", ["device": sender.id])
		do {
			try await client.send(.sasNonce(attempt.nonceMessage(macLink: macLink)), to: sender)
		} catch {
			log("account.sas_send_failed", ["device": sender.id, "detail": (error as? LinkError)?.code ?? "\(type(of: error))"])
		}
	}

	/// `sas_reveal`: opens the attempt's commitment with the keys the account lists for the
	/// sender. Refused without an attempt (a reveal before any commit); a reveal that does not
	/// open it, or names other keys, fails the attempt for good.
	private func finishSafetyNumber(_ reveal: SASReveal, from sender: TrustedDevice) {
		guard sender.platform == .ios, var attempt = state?.sas?[sender.id], let myID = state?.device_id,
			let macLink = macLinkKey()
		else {
			log("account.sas_refused", ["device": sender.id, "detail": "reveal without a commitment"])
			return
		}
		do {
			_ = try attempt.receive(
				reveal, phoneID: sender.id, macID: myID, macLink: macLink, listedLink: sender.linkKey,
				listedApprove: sender.approveKey)
			log("account.sas_ready", ["device": sender.id])
		} catch SASError.attemptMismatch {
			log("account.sas_refused", ["device": sender.id, "detail": "reveal for another attempt"])
			return
		} catch {
			log("account.sas_failed", ["device": sender.id, "detail": "\(error)"])
		}
		state?.sas?[sender.id] = attempt
		saveState()
	}

	/// The latest attempt with `deviceID` (tests).
	func safetyNumberAttempt(_ deviceID: String) -> SASResponder? {
		state?.sas?[deviceID]
	}

	/// Opens and handles whatever the relay holds now (tests drive the exchange with it).
	func processMessages() async throws {
		try await serialized { try await self.pollMessagesLocked(wait: 0) }
	}

	// MARK: Helpers

	/// A response's frames, `width` sends at a time: each is a relay round trip, and the phone
	/// puts them back in order. A frame the relay refuses fails the whole response.
	static func sendFrames(
		_ messages: [LinkMessage], to recipient: TrustedDevice, client: RelayClient, width: Int = 3
	) async throws {
		guard messages.count > 1, width > 1 else { return try await client.send(messages, to: recipient, ttl: RelayAPI.ttl) }
		try await withThrowingTaskGroup(of: Void.self) { group in
			var next = 0
			func add() {
				let message = messages[next]
				next += 1
				group.addTask { _ = try await client.send(message, to: recipient, ttl: RelayAPI.ttl) }
			}
			while next < min(width, messages.count) { add() }
			while try await group.next() != nil {
				if next < messages.count { add() }
			}
		}
	}

	static func offerDigest(_ context: OfferContext, approveConfirmed: Bool) -> String {
		var parts = [context.baseURLs.joined(separator: ","), context.daemonFP, context.macName, "\(approveConfirmed)"]
		// Only when on, so turning it off restores the digest offers already sent had.
		if context.allowLANHTTP { parts.append("allow_lan_http") }
		return LinkCrypto.sha256Hex(Data(parts.joined(separator: "\n").utf8))
	}

	static func trimmed(_ url: String) -> String {
		var url = url
		while url.hasSuffix("/") { url.removeLast() }
		return url
	}
}

/// Where a phone can reach this helper directly. A configured `public_url` leads; loopback-only
/// listeners offer loopback. Otherwise the tailnet addresses, and only with plain-LAN access on
/// (`DirectAccessPolicy`) the local network addresses and the Bonjour host name: a URL the
/// helper would refuse at accept is never offered.
enum OfferAddresses {
	typealias Interface = DirectAccessPolicy.InterfaceAddress

	/// Within the tailnet the MagicDNS name leads, then the IPv6 address, then the 100.x one:
	/// iOS App Transport Security lets an app reach `*.ts.net` and IPv6 over plain HTTP, but
	/// treats 100.64.0.0/10 as the internet.
	static func baseURLs(
		config: HelperConfig, port: Int, override: [String] = [], allowLAN: Bool = false,
		interfaces: [Interface]? = nil, tailnetName: String? = nil
	) -> [String] {
		if !override.isEmpty { return override }
		var out: [String] = []
		func add(_ url: String) { if !out.contains(url) { out.append(url) } }
		let configured = AccountLink.trimmed(config.publicURL)
		if !configured.isEmpty { add(configured) }
		if HelperConfig.loopbackHosts.contains(config.listenHost) {
			add("http://127.0.0.1:\(port)")
			return out
		}
		let addresses = interfaces ?? DirectAccessPolicy.interfaceAddresses()
		// Only this Mac's own Tailscale addresses: a carrier-NAT 100.x on Wi-Fi is not the tailnet.
		let ownTailnet = DirectAccessPolicy.ownTailnetAddresses(addresses)
		func offerable(_ ip: String) -> Bool {
			if ownTailnet.contains(DirectAccessPolicy.normalize(ip)) { return true }
			return allowLAN && DirectAccessPolicy.classify(ip) == .localNetwork
		}
		if config.listenHost != "0.0.0.0", config.listenHost != "::", !config.listenHost.isEmpty {
			let host = config.listenHost.contains(":") ? "[\(config.listenHost)]" : config.listenHost
			if offerable(config.listenHost) { add("http://\(host):\(port)") }
			return out
		}
		let v4 = addresses.map(\.ip).filter { DirectAccessPolicy.parse($0)?.count == 4 && !$0.contains(":") }
		if !ownTailnet.isEmpty, let name = tailnetName, !name.isEmpty { add("http://\(name):\(port)") }
		for ip in ownTailnet.sorted() where ip.contains(":") { add("http://[\(ip)]:\(port)") }
		for ip in v4 where ownTailnet.contains(ip) { add("http://\(ip):\(port)") }
		guard allowLAN else { return out }
		for ip in v4 where !ip.hasPrefix("169.254.") && DirectAccessPolicy.classify(ip) == .localNetwork {
			add("http://\(ip):\(port)")
		}
		let (derived, _) = config.effectivePublicURL(boundPort: port)
		add(derived)
		return out
	}

	/// The address a pairing code's QR carries: the first offered one, else the Bonjour name
	/// (which the helper refuses until plain-LAN access is on or the phone joins the tailnet).
	static func pairingURL(
		config: HelperConfig, port: Int, allowLAN: Bool, interfaces: [Interface]? = nil, tailnetName: String? = nil
	) -> String {
		baseURLs(config: config, port: port, allowLAN: allowLAN, interfaces: interfaces, tailnetName: tailnetName).first
			?? config.effectivePublicURL(boundPort: port).0
	}

	/// 100.64.0.0/10, the CGNAT range Tailscale hands out.
	static func isTailscale(_ ip: String) -> Bool {
		let octets = ip.split(separator: ".").compactMap { Int($0) }
		return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
	}
}
