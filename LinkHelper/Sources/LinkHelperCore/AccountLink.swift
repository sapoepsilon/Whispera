import CryptoKit
import Foundation
import WhisperaLink

/// Account pairing on the Mac (step 11): the helper joins the owner's Whispera account once,
/// then keeps its DeviceRegistry in step with the account's iPhones — no pairing code.
///
/// - `connect` registers the Mac (`platform: macos`, the relay link key, a KEM record) with the
///   account bearer the app hands over, unless it already is, and persists the device id.
/// - The sync loop lists the account's devices over WL1 (`GET /v1/device/peers`), pins every
///   active, verified iPhone under its account device id with approve rights pending, and
///   sends each a sealed `link_offer` — once, and again only when what the offer says changes.
///   Phones revoked or gone from the list are revoked here, so the HTTP API answers
///   `auth_revoked`, and nothing is sent to them.
/// - Relay messages are read with a long poll; only `unpaired` from a verified iPhone of the
///   account is acted on.
/// - `confirmApprove` (the owner's Touch ID in the app) unlocks approvals for a phone and tells
///   it with `approve_confirmed`.
///
/// The bearer is used for registration only and never stored.
public actor AccountLink {
	/// What a link offer advertises about this Mac, read when an offer is built.
	public struct OfferContext: Sendable, Equatable {
		public var baseURLs: [String]
		public var daemonPubkeyB64: String
		public var daemonFP: String
		public var macName: String

		public init(baseURLs: [String], daemonPubkeyB64: String, daemonFP: String, macName: String) {
			self.baseURLs = baseURLs
			self.daemonPubkeyB64 = daemonPubkeyB64
			self.daemonFP = daemonFP
			self.macName = macName
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
	}

	public struct SyncReport: Sendable, Equatable {
		public var pinned: [String] = []
		public var offered: [String] = []
		public var dropped: [String] = []
		public var untrusted: [String] = []
	}

	private let paths: HelperConfig.Paths
	private let devices: DeviceRegistry
	private let push: SwitchablePush
	private let transport: LinkTransport
	private let log: OpsLog
	private let offerContext: @Sendable () -> OfferContext
	private let clock: @Sendable () -> Int
	private let pollWait: Int
	private var state: State?
	private var snapshot: AccountDevices?
	private var loop: Task<Void, Never>?
	private var tail: Task<Void, Never>?
	private var status = "signed_out"

	public init(
		paths: HelperConfig.Paths, devices: DeviceRegistry, push: SwitchablePush,
		transport: LinkTransport = URLSessionLinkTransport(), pollWait: Int = 25, log: OpsLog = .null,
		clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
		offerContext: @escaping @Sendable () -> OfferContext
	) {
		self.paths = paths
		self.devices = devices
		self.push = push
		self.transport = transport
		self.pollWait = pollWait
		self.log = log
		self.clock = clock
		self.offerContext = offerContext
		if let data = FileManager.default.contents(atPath: paths.accountState),
			let loaded = try? JSONDecoder().decode(State.self, from: data),
			LinkCrypto.isValidDeviceID(loaded.device_id)
		{
			state = loaded
			status = "registered"
		}
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

	public func pendingConfirmations() -> [[String: Any]] {
		devices.pendingApproveConfirmations().map(Self.confirmationObject)
	}

	/// The owner confirmed `deviceID`'s approve key (Touch ID in the app). Marks it and, for an
	/// account phone, sends it `approve_confirmed`.
	public func confirmApprove(_ deviceID: String) async throws -> [String: Any] {
		guard let record = try devices.confirmApprove(deviceID) else {
			throw APIError(404, "not_found", "no such active device")
		}
		log("device.approve_confirmed", ["device": deviceID])
		var sent = false
		if record.origin == .account, state != nil {
			sent = (try? await serialized { try await self.sendApproveConfirmedLocked(deviceID) }) ?? false
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
	}

	static func confirmationObject(_ record: DeviceRecord) -> [String: Any] {
		let fingerprint =
			(try? LinkPublicKey(x963Base64: record.approvePubkey).displayFingerprint) ?? record.approveFP
		let linkFingerprint = (try? LinkPublicKey(x963Base64: record.linkPubkey).displayFingerprint) ?? record.linkFP
		return [
			"device_id": record.deviceID, "name": record.name, "platform": "ios", "approve_fp": record.approveFP,
			"fingerprint": fingerprint, "link_fingerprint": linkFingerprint, "created_at": record.createdAt,
		]
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
		let wait = pollWait
		loop = Task { [weak self] in
			var backoff: UInt64 = 1
			while !Task.isCancelled {
				guard let self else { return }
				do {
					try await self.serialized {
						_ = try await self.syncPeersLocked()
					}
					let started = Date()
					try await self.serialized { try await self.pollMessagesLocked(wait: wait) }
					backoff = 1
					// A relay that answers at once (no long poll, or wait 0) still gets a breather.
					if Date().timeIntervalSince(started) < 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
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
				return
			}
			// Signed into another account, or this Mac was revoked: start over with new keys.
			log("account.reregister", ["device": state.device_id])
			dropAccountPins(reason: "account_changed")
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
		state = nil
		snapshot = nil
		status = "signed_out"
		try? FileManager.default.removeItem(atPath: paths.accountState)
		push.replace(with: UnconfiguredPush())
		log("account.disconnected")
	}

	private func dropAccountPins(reason: String) {
		for record in devices.active() where record.origin == .account {
			devices.revoke(record.deviceID)
			log("device.revoked", ["device": record.deviceID, "detail": reason])
		}
	}

	private func activatePush() {
		if let client = try? client() { push.replace(with: RelayPush(client: client, log: log)) }
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

		for phone in account.phones where !unpaired.contains(phone.id) {
			guard let approve = phone.approveKey else {
				log("account.skip", ["device": phone.id, "detail": "no approve key"])
				continue
			}
			let pinned: (record: DeviceRecord, isNew: Bool)
			do {
				pinned = try devices.pinAccountDevice(
					deviceID: phone.id, name: phone.name, link: phone.linkKey, approve: approve,
					sttKeySHA256: "")
			} catch {
				log("account.skip", ["device": phone.id, "detail": "pin failed"])
				continue
			}
			guard !pinned.record.isRevoked else { continue }
			keep.insert(phone.id)
			if pinned.isNew {
				report.pinned.append(phone.id)
				log("device.pinned", ["device": phone.id, "detail": "account approve=pending"])
			}
			let digest = Self.offerDigest(context, approveConfirmed: pinned.record.approveConfirmed)
			if pinned.isNew || state?.offers[phone.id] != digest {
				if try await sendOffer(client, to: phone, record: pinned.record, context: context, myID: myID) {
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
			mac_name: context.macName, approve_confirmed: record.approveConfirmed)
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

	private func sendApproveConfirmedLocked(_ deviceID: String) async throws -> Bool {
		let client = try client()
		if snapshot?.peer(deviceID) == nil { _ = try await syncPeersLocked() }
		guard let peer = snapshot?.peer(deviceID) else { return false }
		try await client.send(.approveConfirmed(deviceID: deviceID), to: peer)
		if let record = devices.get(deviceID) {
			state?.offers[deviceID] = Self.offerDigest(offerContext(), approveConfirmed: record.approveConfirmed)
			saveState()
		}
		log("account.approve_confirmed_sent", ["device": deviceID])
		return true
	}

	private func pollMessagesLocked(wait: Int) async throws {
		let client = try client()
		let after = state?.cursor ?? 0
		let messages = try await client.messages(after: after, wait: wait)
		guard !messages.isEmpty else { return }
		let agreement = try agreementKey()
		var refreshed = false
		var last = after
		for relayed in messages.sorted(by: { $0.seq < $1.seq }) {
			last = max(last, relayed.seq)
			var account = snapshot ?? AccountDevices(classifying: [], selfID: state?.device_id)
			if account.peer(relayed.from) == nil && !refreshed {
				_ = try? await syncPeersLocked()
				refreshed = true
				account = snapshot ?? account
			}
			let received: ReceivedLinkMessage
			do {
				received = try client.openLinkMessage(relayed, devices: account, agreementKey: agreement)
			} catch {
				log("account.message_rejected", ["device": relayed.from, "detail": "\(type(of: error))"])
				continue
			}
			handle(received)
		}
		_ = try? await client.ack(upTo: last)
		state?.cursor = last
		saveState()
	}

	private func handle(_ received: ReceivedLinkMessage) {
		let sender = received.sender
		switch received.message {
		case .unpaired(let id):
			guard sender.platform == .ios, id == sender.id || id == state?.device_id else {
				log("account.message_ignored", ["device": sender.id, "detail": "unpaired for another device"])
				return
			}
			if let record = devices.get(sender.id), record.origin == .account {
				devices.revoke(sender.id)
			}
			if state?.unpaired.contains(sender.id) == false { state?.unpaired.append(sender.id) }
			state?.offers[sender.id] = nil
			log("device.revoked", ["device": sender.id, "detail": "phone unpaired"])
		case .linkOffer, .approveConfirmed:
			log("account.message_ignored", ["device": sender.id, "detail": received.message.type])
		}
	}

	// MARK: Helpers

	static func offerDigest(_ context: OfferContext, approveConfirmed: Bool) -> String {
		let parts = [context.baseURLs.joined(separator: ","), context.daemonFP, context.macName, "\(approveConfirmed)"]
		return LinkCrypto.sha256Hex(Data(parts.joined(separator: "\n").utf8))
	}

	static func trimmed(_ url: String) -> String {
		var url = url
		while url.hasSuffix("/") { url.removeLast() }
		return url
	}
}

/// Where a phone can reach this helper: LAN addresses first, then Tailscale, then the
/// Bonjour host name. A configured `public_url` leads; loopback-only listeners offer loopback.
enum OfferAddresses {
	static func baseURLs(config: HelperConfig, port: Int, override: [String] = []) -> [String] {
		if !override.isEmpty { return override }
		var out: [String] = []
		func add(_ url: String) { if !out.contains(url) { out.append(url) } }
		let configured = AccountLink.trimmed(config.publicURL)
		if !configured.isEmpty { add(configured) }
		if HelperConfig.loopbackHosts.contains(config.listenHost) {
			add("http://127.0.0.1:\(port)")
			return out
		}
		if config.listenHost != "0.0.0.0", config.listenHost != "::", !config.listenHost.isEmpty {
			add("http://\(config.listenHost):\(port)")
			return out
		}
		let addresses = interfaceIPv4()
		for ip in addresses where !isTailscale(ip) { add("http://\(ip):\(port)") }
		for ip in addresses where isTailscale(ip) { add("http://\(ip):\(port)") }
		let (derived, _) = config.effectivePublicURL(boundPort: port)
		add(derived)
		return out
	}

	/// 100.64.0.0/10, the CGNAT range Tailscale hands out.
	static func isTailscale(_ ip: String) -> Bool {
		let octets = ip.split(separator: ".").compactMap { Int($0) }
		return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
	}

	/// IPv4 addresses of up, running, non-loopback interfaces; link-local skipped.
	static func interfaceIPv4() -> [String] {
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return [] }
		defer { freeifaddrs(head) }
		var out: [String] = []
		var cursor: UnsafeMutablePointer<ifaddrs>? = first
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			let flags = Int32(entry.pointee.ifa_flags)
			guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
				flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
			else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard
				getnameinfo(
					address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
					== 0
			else { continue }
			let ip = String(cString: host)
			if ip.hasPrefix("169.254.") || out.contains(ip) { continue }
			out.append(ip)
		}
		return out
	}
}
