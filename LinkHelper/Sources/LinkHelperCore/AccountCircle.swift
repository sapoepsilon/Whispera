import Foundation
import WhisperaLink

/// Linking the owner's devices without comparing numbers, on top of account pairing.
///
/// The account backend lists every device's keys, but a listing proves nothing: a compromised
/// backend could list devices of its own. Neither does the owner's tailnet (every untagged node
/// of the owner's Tailscale user looks the same there, and a node's OS is what it says), nor
/// another helper's word (its state is files any process of its user can write). So **only the
/// owner's act on this device grants trust here**; everything else only saves a number:
///
/// 1. **Link a Mac** (Touch ID): this helper probes the owner's tailnet Macs on their helper
///    port; one that proves the link key the account lists for a Mac becomes a *candidate*,
///    shown as "Link mac-b?" with its tailnet name, when its node was first seen, the
///    account name and the key's fingerprint. Approving it makes it a linked Mac here.
/// 2. **Allow a vouched iPhone** (Touch ID): a linked Mac signs a `DeviceVouch` for each phone
///    whose safety number the owner compared there. Here that phone gets "Allow iPhone X,
///    vouched by Mac Y?" instead of a safety number; the owner's tap confirms it, nothing else.
/// 3. A linked Mac's vouch for another Mac is shown on that Mac's card as a hint only.
///
/// A vouch is what the voucher's helper *says*: it is signed with that helper's account key,
/// which lives in a file its user's processes can read, so a hijacked process there could make
/// one up. Cards therefore word it as a claim ("Mac Y says…"), and nothing is trusted on it.
///
/// Vouches expire (30 days), are re-signed while they hold, and count only while fresh from
/// the voucher's last answer. Node bindings and links survive a missed account listing; only
/// an explicit Unlink removes them.
public final class AccountCircle: @unchecked Sendable {
	/// A listed Mac that proved its link key from a node of the owner's tailnet: shown, not trusted.
	struct Candidate: Codable, Equatable {
		var keys: PinnedDeviceKeys
		var name: String
		var tailnet_name: String
		var address: String
		var seen_at: Int
		var node_id: String?
	}

	/// A Mac the owner linked here, with the keys it had then.
	struct Approved: Codable, Equatable {
		var keys: PinnedDeviceKeys
		var name: String
		var tailnet_name: String
		var approved_at: Int
	}

	/// The tailnet node a listed Mac answered from.
	struct NodeBinding: Codable, Equatable {
		var id: String
		var first_seen: Int
	}

	/// `circle.json`. Every field decodes with a default, so a newer or older file loads.
	struct State: Codable, Equatable {
		var candidates: [String: Candidate] = [:]
		var approved: [String: Approved] = [:]
		/// `device id|link key` of Macs the owner declined or unlinked here.
		var declined: [String] = []
		/// The vouches each Mac served on its last answer (replaced on every fetch).
		var received: [String: [DeviceVouch]] = [:]
		var received_at: [String: Int] = [:]
		/// Listed Mac → the node it first answered from. One node is one Mac.
		var nodes: [String: NodeBinding] = [:]

		init() {}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			candidates = try c.decodeIfPresent([String: Candidate].self, forKey: .candidates) ?? [:]
			approved = try c.decodeIfPresent([String: Approved].self, forKey: .approved) ?? [:]
			declined = try c.decodeIfPresent([String].self, forKey: .declined) ?? []
			received = try c.decodeIfPresent([String: [DeviceVouch]].self, forKey: .received) ?? [:]
			received_at = try c.decodeIfPresent([String: Int].self, forKey: .received_at) ?? [:]
			nodes = try c.decodeIfPresent([String: NodeBinding].self, forKey: .nodes) ?? [:]
		}
	}

	struct Identity {
		var deviceID: String
		var key: LinkSigningKey
	}

	static let helloContext = "WL1-PEER-HELLO"
	static let proofContext = "WL1-PEER-PROOF"
	static let helloSkew = 120
	static let eagerProbeInterval: UInt64 = 20
	static let idleProbeInterval: UInt64 = 300
	/// A voucher's set counts only this long after its last answer.
	static let receivedFreshness = 3600
	/// Probes in flight at once.
	static let probeConcurrency = 4

	let path: String
	let tailnet: TailnetIdentity?
	private let http: PeerHTTP
	private let defaultPort: Int
	private let clock: @Sendable () -> Int
	private let log: OpsLog
	private let lock = NSLock()
	private var state = State()
	private var saved: State?
	/// Set when `circle.json` existed but did not decode; it was moved aside, never overwritten.
	private(set) var loadError: String?
	private var identity: Identity?
	private var lastAccount: AccountDevices?
	private var listedMacs: [String: TrustedDevice] = [:]
	private var needsTrust = true
	private var published: [DeviceVouch] = []
	private var issued: [String: DeviceVouch] = [:]
	private var loop: Task<Void, Never>?
	private var hints: Set<String> = []
	private var seenNonces: [String: Int] = [:]
	private var schedule = ProbeSchedule()
	/// Listed Mac → the tailnet name it last answered from while bound to another node.
	private var moved: [String: String] = [:]

	public init(
		path: String, tailnet: TailnetIdentity?, defaultPort: Int, log: OpsLog = .null,
		clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
	) {
		self.path = path
		self.tailnet = tailnet
		http = PeerHTTP(allowsHost: { tailnet?.isProbeAddress($0) ?? false })
		self.defaultPort = defaultPort
		self.log = log
		self.clock = clock
		if let data = FileManager.default.contents(atPath: path) {
			do {
				let loaded = try JSONDecoder().decode(State.self, from: data)
				state = loaded
				saved = loaded
			} catch {
				let aside = path + ".unreadable-\(clock())"
				try? FileManager.default.moveItem(atPath: path, toPath: aside)
				loadError = "circle.json did not decode; kept as \((aside as NSString).lastPathComponent)"
				log("circle.state_unreadable", ["detail": String("\(error)".prefix(120))])
			}
		}
	}

	// MARK: Identity and listing

	func setIdentity(_ identity: Identity?) {
		lock.withLock {
			if identity?.deviceID != self.identity?.deviceID { issued = [:] }
			self.identity = identity
		}
	}

	/// Signed out or joined another account: nothing learned under the old id counts.
	func reset() {
		stop()
		lock.withLock {
			state = State()
			saved = nil
			issued = [:]
			published = []
			identity = nil
			listedMacs = [:]
			lastAccount = nil
			schedule = ProbeSchedule()
		}
		try? FileManager.default.removeItem(atPath: path)
	}

	/// The account as the last sync saw it. Links, node bindings and candidates are kept when a
	/// Mac is missing from one listing (only Unlink removes them); they simply count for nothing
	/// while the Mac is not listed with the pinned keys.
	func update(account: AccountDevices, needsTrust: Bool) {
		lock.withLock {
			lastAccount = account
			listedMacs = Dictionary(account.macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
			self.needsTrust = needsTrust || pendingLocked().count > 0
				|| account.macs.contains { state.approved[$0.id] == nil }
		}
	}

	// MARK: Probing (its own task, never the account actor)

	func start(onChange: @escaping @Sendable () -> Void) {
		guard tailnet != nil else { return }
		lock.withLock {
			guard loop == nil else { return }
			loop = Task { [weak self] in
				while !Task.isCancelled {
					guard let self else { return }
					if await self.probeNow() { onChange() }
					let eager = self.lock.withLock { self.needsTrust }
					let seconds = eager ? Self.eagerProbeInterval : Self.idleProbeInterval
					try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
				}
			}
		}
	}

	func stop() {
		lock.withLock {
			loop?.cancel()
			loop = nil
		}
		http.invalidate()
	}

	deinit {
		http.invalidate()
	}

	/// One round: probes the owner's tailnet Macs that are due, at most `probeConcurrency` at a
	/// time. `force` ignores the backoff (tests, and right after the owner linked a Mac).
	@discardableResult
	func probeNow(force: Bool = false) async -> Bool {
		guard let tailnet, let identity = lock.withLock({ identity }) else { return false }
		var nodes = await tailnet.ownerMacs()
		let hinted = lock.withLock {
			let out = hints
			hints = []
			return out
		}
		for address in hinted.sorted() where !nodes.contains(where: { $0.address == address && $0.port == nil }) {
			nodes.append(TailnetPeer(address: address))
		}
		let now = clock()
		let due = lock.withLock { nodes.filter { force || schedule.isDue(target(of: $0), now: now) } }
		let before = lock.withLock { state }
		await withTaskGroup(of: Void.self) { group in
			var running = 0
			for node in due {
				if running == Self.probeConcurrency {
					await group.next()
					running -= 1
				}
				group.addTask { await self.probe(node, tailnet: tailnet, identity: identity) }
				running += 1
			}
		}
		save()
		return lock.withLock { state } != before
	}

	private func target(of node: TailnetPeer) -> String {
		"\(node.address):\(node.port ?? defaultPort)"
	}

	/// The only way a Mac becomes a candidate: this helper connects out to the node's helper
	/// port, `whois` of that exact address:port names an owner node reporting macOS that is not
	/// this one, and the answer proves the link key the account lists for a Mac not bound to
	/// another node. A Mac that answers but is never linked is probed less and less often.
	private func probe(_ node: TailnetPeer, tailnet: TailnetIdentity, identity: Identity) async {
		let target = target(of: node)
		let now = clock()
		var outcome = ProbeSchedule.Outcome.nothing
		defer { lock.withLock { schedule.record(target, outcome, now: now) } }
		guard let tailnetNode = await Task.detached(operation: { tailnet.whois(target) }).value,
			tailnetNode.id != tailnet.selfNodeID
		else { return }
		let nonce = LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		let ts = clock()
		guard let signature = try? identity.key.sign(Self.helloBytes(nonce: nonce, ts: ts, from: identity.deviceID))
		else { return }
		var query = URLComponents()
		query.queryItems = [
			URLQueryItem(name: "from", value: identity.deviceID), URLQueryItem(name: "nonce", value: nonce),
			URLQueryItem(name: "ts", value: String(ts)),
			URLQueryItem(name: "sig", value: LinkCrypto.base64URLNoPad(signature)),
		]
		guard let encoded = query.percentEncodedQuery,
			let body = await http.get(host: node.address, port: node.port ?? defaultPort, target: "/v1/link/peer?" + encoded),
			let proof = try? JSONDecoder().decode(PeerProof.self, from: body)
		else { return }
		guard proof.device_id != identity.deviceID, let mac = lock.withLock({ listedMacs[proof.device_id] }),
			mac.linkKey.x963Base64 == proof.link_pubkey, proof.approve_pubkey == mac.approveKey?.x963Base64,
			proof.kem_pubkey == mac.agreementKey.x963Base64, let proofSignature = Data(base64Encoded: proof.signature),
			mac.linkKey.isValidSignature(proofSignature, for: proof.signedBytes(nonce: nonce, verifier: identity.deviceID))
		else {
			log("circle.peer_refused", ["detail": "not a listed Mac with those keys"])
			return
		}
		// The prover names its own node; a node relaying another Mac's helper answers with a
		// node id that is not the one `whois` names for the address this probe connected to.
		guard proof.node_id == tailnetNode.id else {
			log("circle.peer_refused", ["device": mac.id, "detail": "answered for node \(proof.node_id), connected to \(tailnetNode.name)"])
			return
		}
		let vouches = Array(proof.vouches.filter { $0.voucher_id == mac.id && $0.isWellFormed }.prefix(VouchTrust.maxPerVoucher))
		let refusal: String? = lock.withLock {
			if let other = state.nodes.first(where: { $0.value.id == tailnetNode.id && $0.key != mac.id })?.key {
				state.received[mac.id] = nil
				state.received_at[mac.id] = nil
				return "node \(tailnetNode.name) already answers as \(other)"
			}
			if let bound = state.nodes[mac.id], bound.id != tailnetNode.id {
				state.received[mac.id] = nil
				state.received_at[mac.id] = nil
				moved[mac.id] = tailnetNode.name
				return "first seen on another node; Relink it to link it from \(tailnetNode.name)"
			}
			moved[mac.id] = nil
			if state.nodes[mac.id] == nil { state.nodes[mac.id] = NodeBinding(id: tailnetNode.id, first_seen: now) }
			noteCandidateLocked(mac, node: tailnetNode, address: node.address)
			state.received[mac.id] = vouches
			state.received_at[mac.id] = now
			outcome = state.approved[mac.id]?.keys.matches(mac) == true ? .linked : .unlinked
			return nil
		}
		if let refusal { log("circle.peer_refused", ["device": mac.id, "detail": refusal]) }
	}

	private func noteCandidateLocked(_ mac: TrustedDevice, node: TailnetNode, address: String) {
		let keys = PinnedDeviceKeys(mac)
		if state.candidates[mac.id]?.keys != keys || state.candidates[mac.id]?.node_id != node.id {
			log("circle.candidate", ["device": mac.id, "detail": "tailnet=\(node.name)"])
		}
		state.candidates[mac.id] = Candidate(
			keys: keys, name: DeviceRegistry.sanitizedName(mac.name), tailnet_name: node.name, address: address,
			seen_at: clock(), node_id: node.id)
	}

	// MARK: Serving the hello

	/// `GET /v1/link/peer?from&nonce&ts&sig`: another helper of this account says who it is.
	/// Answered only when `from` is a Mac the account lists, `sig` is its link key's signature
	/// over a fresh, unreplayed hello, and `tailscale whois` of the caller's address is an owner
	/// node. A hello never makes a candidate: it only asks to be probed back. The answer is this
	/// helper's own proof and the vouches it issued (none to a declined Mac). Else nil (404).
	func hello(_ query: [String: String], caller: String) -> Data? {
		guard let tailnet, let me = lock.withLock({ identity }),
			let from = query["from"], LinkCrypto.isValidDeviceID(from), from != me.deviceID,
			let nonce = query["nonce"], Self.isValidNonce(nonce), let ts = query["ts"].flatMap(Int.init),
			abs(clock() - ts) <= Self.helloSkew, let sig = query["sig"].flatMap(Self.base64URLDecode),
			let mac = lock.withLock({ listedMacs[from] }),
			mac.linkKey.isValidSignature(sig, for: Self.helloBytes(nonce: nonce, ts: ts, from: from)),
			fresh(from: from, nonce: nonce), let callerNode = tailnet.whois(caller), let myNode = tailnet.selfNodeID,
			let mine = lock.withLock({ lastAccount?.me })
		else { return nil }
		// A Mac bound to a node here says hello only from that node.
		if let bound = lock.withLock({ state.nodes[from] }), bound.id != callerNode.id { return nil }
		let vouches: [DeviceVouch] = lock.withLock {
			hints.insert(caller)
			return isDeclinedLocked(mac) ? [] : published
		}
		var proof = PeerProof(
			v: 3, device_id: me.deviceID, link_pubkey: me.key.publicKey.x963Base64,
			approve_pubkey: mine.approveKey?.x963Base64, kem_pubkey: mine.agreementKey.x963Base64, node_id: myNode,
			signature: "", vouches: vouches)
		guard let signature = try? me.key.sign(proof.signedBytes(nonce: nonce, verifier: from)) else { return nil }
		proof.signature = signature.base64EncodedString()
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try? encoder.encode(proof)
	}

	private func fresh(from: String, nonce: String) -> Bool {
		let now = clock()
		return lock.withLock {
			seenNonces = seenNonces.filter { now - $0.value <= 2 * Self.helloSkew }
			let key = from + "|" + nonce
			guard seenNonces[key] == nil, seenNonces.count < 4096 else { return false }
			seenNonces[key] = now
			return true
		}
	}

	struct PeerProof: Codable {
		var v: Int
		var device_id: String
		var link_pubkey: String
		var approve_pubkey: String?
		var kem_pubkey: String
		/// The prover's own Tailscale node (stable id), from its `tailscale status`.
		var node_id: String
		var signature: String
		var vouches: [DeviceVouch]

		/// `WL1-PEER-PROOF\n<nonce>\n<verifier>\n<prover>\n<link>\n<approve or ->\n<kem>\n<node id>`.
		func signedBytes(nonce: String, verifier: String) -> Data {
			Data(
				[
					AccountCircle.proofContext, nonce, verifier, device_id, link_pubkey, approve_pubkey ?? "-", kem_pubkey,
					node_id,
				].joined(separator: "\n").utf8)
		}
	}

	static func helloBytes(nonce: String, ts: Int, from: String) -> Data {
		Data([helloContext, nonce, String(ts), from].joined(separator: "\n").utf8)
	}

	static func isValidNonce(_ nonce: String) -> Bool {
		(16...64).contains(nonce.count)
			&& nonce.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
	}

	static func base64URLDecode(_ text: String) -> Data? {
		guard text.count <= 200 else { return nil }
		var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while base.count % 4 != 0 { base += "=" }
		return Data(base64Encoded: base)
	}

	// MARK: Linking Macs

	private static func marker(_ id: String, _ link: String) -> String { id + "|" + link }

	private func isDeclinedLocked(_ mac: TrustedDevice) -> Bool {
		state.declined.contains(Self.marker(mac.id, mac.linkKey.x963Base64))
	}

	private func pendingLocked() -> [(TrustedDevice, Candidate, Bool)] {
		state.candidates.compactMap { id, candidate in
			guard let mac = listedMacs[id], candidate.keys.matches(mac), !isDeclinedLocked(mac),
				state.nodes[id]?.id == candidate.node_id
			else { return nil }
			if let approved = state.approved[id], approved.keys.matches(mac) { return nil }
			return (mac, candidate, state.approved[id] != nil)
		}
		.sorted { $0.0.id < $1.0.id }
	}

	/// The "Link mac-b?" cards, with when the node was first seen and, as a hint only,
	/// which linked Mac vouches for it too.
	func pendingLinks() -> [[String: Any]] {
		let hints = vouchHints()
		return lock.withLock {
			pendingLocked().map { mac, candidate, keyChanged in
				var card: [String: Any] = [
					"device_id": mac.id, "name": candidate.name, "tailnet_name": candidate.tailnet_name,
					"link_fingerprint": mac.linkKey.displayFingerprint, "key_changed": keyChanged,
					"first_seen": state.nodes[mac.id]?.first_seen ?? candidate.seen_at,
					"node_id": candidate.node_id ?? "",
				]
				if let hint = hints[mac.id] { card["vouched_by"] = hint }
				return card
			}
		}
	}

	/// Names of linked Macs whose fresh vouch covers a device, by device id: a hint for a card.
	func vouchHints() -> [String: String] {
		guard let account = lock.withLock({ lastAccount }) else { return [:] }
		return accepted(account: account).compactMapValues { vouch in
			lock.withLock { state.approved[vouch.voucher_id]?.name }
		}
	}

	func approveLink(_ deviceID: String, tailnetName: String, linkFingerprint: String, name: String, nodeID: String) throws {
		try lock.withLock {
			guard let entry = pendingLocked().first(where: { $0.0.id == deviceID }) else {
				throw APIError(404, "not_found", "no such Mac waiting to be linked")
			}
			let (mac, candidate, _) = entry
			guard candidate.tailnet_name == tailnetName, mac.linkKey.displayFingerprint == linkFingerprint,
				candidate.keys.linkPubkey == mac.linkKey.x963Base64, candidate.name == name, candidate.node_id == nodeID,
				state.nodes[deviceID]?.id == nodeID
			else {
				throw APIError(409, "keys_changed", "this Mac changed since the card was shown; check again")
			}
			state.approved[deviceID] = Approved(
				keys: PinnedDeviceKeys(mac), name: candidate.name, tailnet_name: candidate.tailnet_name, approved_at: clock())
			schedule.reset()
		}
		save()
		log("circle.link_approved", ["device": deviceID])
	}

	/// Don't Link, or Unlink: no longer linked, its vouches no longer count, it gets none from
	/// here, its card stays away for these keys, and its node binding is forgotten.
	func declineLink(_ deviceID: String) throws {
		try lock.withLock {
			let link = listedMacs[deviceID]?.linkKey.x963Base64 ?? state.approved[deviceID]?.keys.linkPubkey
				?? state.candidates[deviceID]?.keys.linkPubkey
			guard let link else { throw APIError(404, "not_found", "no such Mac") }
			let marker = Self.marker(deviceID, link)
			if !state.declined.contains(marker) { state.declined.append(marker) }
			state.declined = Array(state.declined.suffix(256))
			state.approved[deviceID] = nil
			state.received[deviceID] = nil
			state.received_at[deviceID] = nil
			state.nodes[deviceID] = nil
			state.candidates[deviceID] = nil
		}
		save()
		log("circle.link_declined", ["device": deviceID])
	}

	/// Relink: forget this Mac's node binding (and its link, card and vouches) without declining
	/// its keys, so the next probe can bind it afresh, for instance after Tailscale gave its Mac a
	/// new node. It then needs the owner's Link again.
	func relink(_ deviceID: String) throws {
		try lock.withLock {
			guard state.nodes[deviceID] != nil || state.approved[deviceID] != nil || state.candidates[deviceID] != nil else {
				throw APIError(404, "not_found", "no such Mac")
			}
			state.nodes[deviceID] = nil
			state.approved[deviceID] = nil
			state.candidates[deviceID] = nil
			state.received[deviceID] = nil
			state.received_at[deviceID] = nil
			moved[deviceID] = nil
			schedule.reset()
		}
		save()
		log("circle.relink", ["device": deviceID])
	}

	/// Macs whose node binding refused their last answer (moved to another node): a "Relink" row.
	func movedMacs() -> [[String: Any]] {
		lock.withLock {
			moved.compactMap { id, node in
				guard let mac = listedMacs[id] else { return nil }
				return ["device_id": id, "name": DeviceRegistry.sanitizedName(mac.name), "tailnet_name": node]
			}
		}
	}

	func linkedMacs() -> [[String: Any]] {
		lock.withLock {
			state.approved.compactMap { id, approved in
				guard let mac = listedMacs[id], approved.keys.matches(mac) else { return nil }
				return [
					"device_id": id, "name": approved.name, "tailnet_name": approved.tailnet_name,
					"link_fingerprint": mac.linkKey.displayFingerprint, "approved_at": approved.approved_at,
				]
			}
			.sorted { ($0["device_id"] as? String ?? "") < ($1["device_id"] as? String ?? "") }
		}
	}

	// MARK: Vouches (hints)

	/// Listed devices a linked Mac vouches for in its fresh answer. These are hints: they only
	/// let a card skip the number; the owner's tap here is what confirms.
	func accepted(account: AccountDevices) -> [String: DeviceVouch] {
		let now = clock()
		let (roots, vouches, myID) = lock.withLock {
			(
				state.approved.mapValues(\.keys),
				state.received.filter { now - (state.received_at[$0.key] ?? 0) <= Self.receivedFreshness }.values.flatMap { $0 },
				identity?.deviceID ?? account.me?.id
			)
		}
		return VouchTrust.accepted(roots: roots, account: account, vouches: vouches, selfID: myID, now: now)
	}

	/// Re-signs what this helper vouches for: each Mac linked here and each phone whose safety
	/// number was compared here (`ownPhones`), as listed now. Reused until half its life is gone.
	func publish(account: AccountDevices, ownPhones: [TrustedDevice]) {
		guard let identity = lock.withLock({ identity }) else { return }
		let now = clock()
		lock.withLock {
			var subjects: [(TrustedDevice, DeviceVouch.Evidence)] = []
			for mac in account.macs {
				if let approved = state.approved[mac.id], approved.keys.matches(mac) { subjects.append((mac, .ownerApproval)) }
			}
			for phone in ownPhones { subjects.append((phone, .safetyNumber)) }
			var fresh: [String: DeviceVouch] = [:]
			for (device, evidence) in subjects {
				if let cached = issued[device.id], cached.covers(device), cached.evidence == evidence.rawValue,
					cached.expires_at - now > DeviceVouch.lifetime / 2
				{
					fresh[device.id] = cached
				} else if let vouch = try? DeviceVouch.issue(
					voucherID: identity.deviceID, key: identity.key, for: device, evidence: evidence, issuedAt: now)
				{
					fresh[device.id] = vouch
				}
			}
			issued = fresh
			published = fresh.values.sorted { $0.subject_id < $1.subject_id }
		}
	}

	func publishedVouches() -> [DeviceVouch] {
		lock.withLock { published }
	}

	func statusObject() -> [String: Any] {
		lock.withLock {
			[
				"tailnet": tailnet != nil,
				"linked_macs": state.approved.map { ["device_id": $0.key, "name": $0.value.name, "tailnet_name": $0.value.tailnet_name] },
				"pending_links": pendingLocked().count,
				"state_error": loadError ?? NSNull(),
			]
		}
	}

	#if DEBUG
		func receivedCount(_ voucher: String) -> Int {
			lock.withLock { state.received[voucher]?.count ?? 0 }
		}

		/// Tests: what a voucher's last answer said, and when.
		func setReceived(_ vouches: [DeviceVouch], from voucher: String, at time: Int) {
			lock.withLock {
				state.received[voucher] = vouches
				state.received_at[voucher] = time
			}
		}
	#endif

	private func save() {
		let snapshot: State? = lock.withLock {
			guard state != saved else { return nil }
			saved = state
			return state
		}
		guard let snapshot else { return }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		if let data = try? encoder.encode(snapshot) { try? FileStore.writeAtomic(data, to: path) }
	}
}

/// When each probe target is due: every round while it may be linked, less and less often for a
/// Mac that answers but is never linked (or never answers), up to an hour.
struct ProbeSchedule: Equatable {
	enum Outcome { case nothing, unlinked, linked }

	static let base = 20
	static let ceiling = 3600

	private var next: [String: Int] = [:]
	private var delay: [String: Int] = [:]

	func isDue(_ target: String, now: Int) -> Bool {
		now >= (next[target] ?? 0)
	}

	mutating func record(_ target: String, _ outcome: Outcome, now: Int) {
		switch outcome {
		case .linked:
			next[target] = nil
			delay[target] = nil
		case .nothing, .unlinked:
			let wait = min((delay[target] ?? Self.base / 2) * 2, Self.ceiling)
			delay[target] = wait
			next[target] = now + wait
		}
	}

	mutating func reset() {
		next = [:]
		delay = [:]
	}
}
