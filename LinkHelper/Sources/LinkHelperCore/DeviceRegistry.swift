import CryptoKit
import Foundation
import WhisperaLink
import WhisperaLinkServer

/// One paired device (PROTOCOL §3.4). Same `devices.json` shape as the Python daemon.
public struct DeviceRecord: Sendable, Equatable {
	public struct APNs: Sendable, Equatable {
		public var token: String
		public var env: String?
		public var updatedAt: Int
	}

	public var deviceID: String
	public var name: String
	public var linkPubkey: String
	public var approvePubkey: String
	public var linkFP: String
	public var approveFP: String
	public var sttKeySHA256: String
	public var apns: APNs?
	public var app: [String: String]?
	public var createdAt: Int
	public var lastSeenAt: Int
	public var revokedAt: Int?
	/// Whether the Mac's owner confirmed this device (JSON `approve_confirmed`, the name kept for
	/// existing files). A device paired with a code was confirmed by typing that code on the Mac;
	/// one pinned from the account starts unconfirmed and may only read `devices/me` or unpair
	/// itself until the owner compares its safety number and confirms it with Touch ID. An
	/// unconfirmed device gets no agents, events, approvals, pushes, link offer or STT key.
	public var approveConfirmed: Bool
	/// The account device's agreement (KEM) key as the account listed it when it was pinned,
	/// X9.63 base64; empty for a code-paired device.
	public var kemPubkey: String
	/// When a pinned account device's keys last changed (it then starts unconfirmed again).
	public var keyChangedAt: Int?
	/// `code` (paired with a pairing code) or `account` (pinned from the account's device list,
	/// under the account device id).
	public var origin: Origin
	/// What approval pushes to this device say (`PUT /v1/devices/me/push`, step 12): the
	/// request's text sealed for the phone (`named`, the default) or nothing about it.
	public var pushText: PushTextMode

	public enum Origin: String, Sendable {
		case code, account
	}

	public var isRevoked: Bool { revokedAt != nil }

	init?(json: [String: Any]) {
		guard let id = json["device_id"] as? String, let link = json["link_pubkey"] as? String,
			let approve = json["approve_pubkey"] as? String
		else { return nil }
		deviceID = id
		name = json["name"] as? String ?? ""
		linkPubkey = link
		approvePubkey = approve
		linkFP = json["link_fp"] as? String ?? ""
		approveFP = json["approve_fp"] as? String ?? ""
		sttKeySHA256 = json["stt_key_sha256"] as? String ?? ""
		if let apns = json["apns"] as? [String: Any], let token = apns["token"] as? String, !token.isEmpty {
			self.apns = APNs(
				token: token, env: apns["env"] as? String,
				updatedAt: WireJSON.strictInt(apns["updated_at"]) ?? 0)
		}
		app = json["app"] as? [String: String]
		createdAt = WireJSON.strictInt(json["created_at"]) ?? 0
		lastSeenAt = WireJSON.strictInt(json["last_seen_at"]) ?? 0
		revokedAt = WireJSON.strictInt(json["revoked_at"])
		kemPubkey = json["kem_pubkey"] as? String ?? ""
		keyChangedAt = WireJSON.strictInt(json["key_changed_at"])
		// Records written before step 11 have neither field: they were all code-paired, and a
		// code pairing is the owner's confirmation.
		approveConfirmed = json["approve_confirmed"] as? Bool ?? true
		origin = (json["origin"] as? String).flatMap(Origin.init(rawValue:)) ?? .code
		pushText = (json["push_text"] as? String).flatMap(PushTextMode.init(rawValue:)) ?? .named
	}

	init(
		deviceID: String, name: String, link: LinkPublicKey, approve: LinkPublicKey, sttKeySHA256: String,
		apns: APNs?, app: [String: String]?, now: Int, approveConfirmed: Bool = true, origin: Origin = .code
	) {
		self.deviceID = deviceID
		self.name = name
		linkPubkey = link.x963Base64
		approvePubkey = approve.x963Base64
		linkFP = link.fingerprint
		approveFP = approve.fingerprint
		self.sttKeySHA256 = sttKeySHA256
		self.apns = apns
		self.app = app
		createdAt = now
		lastSeenAt = now
		revokedAt = nil
		kemPubkey = ""
		keyChangedAt = nil
		self.approveConfirmed = approveConfirmed
		self.origin = origin
		pushText = .named
	}

	var storedJSON: [String: Any] {
		var out = publicJSON
		out["stt_key_sha256"] = sttKeySHA256
		out["apns"] =
			apns.map { ["token": $0.token, "env": $0.env as Any? ?? NSNull(), "updated_at": $0.updatedAt] }
			?? NSNull()
		return out
	}

	/// The public view (§3.4): no `stt_key_sha256`, the APNs token cut to its last 8 chars.
	public var publicJSON: [String: Any] {
		[
			"device_id": deviceID,
			"name": name,
			"link_pubkey": linkPubkey,
			"approve_pubkey": approvePubkey,
			"link_fp": linkFP,
			"approve_fp": approveFP,
			"apns": apns.map {
				[
					"token": String($0.token.suffix(8)), "env": $0.env as Any? ?? NSNull(),
					"updated_at": $0.updatedAt,
				] as [String: Any]
			} ?? NSNull(),
			"app": app ?? NSNull(),
			"created_at": createdAt,
			"last_seen_at": lastSeenAt,
			"revoked_at": revokedAt ?? NSNull(),
			"approve_confirmed": approveConfirmed,
			"kem_pubkey": kemPubkey.isEmpty ? NSNull() : kemPubkey,
			"key_changed_at": keyChangedAt ?? NSNull(),
			"origin": origin.rawValue,
			"push_text": pushText.rawValue,
		]
	}
}

/// `devices.json` plus the per-device public key PEMs (PROTOCOL §3.4, §3.5).
public final class DeviceRegistry: @unchecked Sendable {
	public static let apnsEnvs: Set<String> = ["sandbox", "production"]
	static let lastSeenMinInterval = 60

	let path: String
	let keysDir: String
	private let clock: @Sendable () -> Int
	private let lock = NSRecursiveLock()
	private var devices: [String: DeviceRecord] = [:]
	private var revokeHooks: [(String) -> Void] = []

	public init(
		path: String, keysDir: String, clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
	) throws {
		self.path = path
		self.keysDir = keysDir
		self.clock = clock
		if let object = try FileStore.readJSON(path) {
			guard let root = object as? [String: Any], let list = root["devices"] as? [[String: Any]] else {
				throw NSError(
					domain: "DeviceRegistry", code: 1,
					userInfo: [NSLocalizedDescriptionKey: "malformed \(path)"])
			}
			for item in list {
				if let record = DeviceRecord(json: item) { devices[record.deviceID] = record }
			}
		}
	}

	public func onRevoke(_ hook: @escaping (String) -> Void) {
		lock.lock()
		revokeHooks.append(hook)
		lock.unlock()
	}

	private func save() throws {
		let list = devices.values.sorted { $0.createdAt < $1.createdAt }.map(\.storedJSON)
		try FileStore.writeJSONAtomic(["v": 1, "devices": list] as [String: Any], to: path)
	}

	public func get(_ deviceID: String) -> DeviceRecord? {
		lock.lock()
		defer { lock.unlock() }
		return devices[deviceID]
	}

	public func all() -> [DeviceRecord] {
		lock.lock()
		defer { lock.unlock() }
		return devices.values.sorted { $0.createdAt < $1.createdAt }
	}

	public func active() -> [DeviceRecord] { all().filter { !$0.isRevoked } }

	public var activeCount: Int { active().count }

	func linkPEMPath(_ id: String) -> String { keysDir + "/" + id + ".link.pem" }
	func approvePEMPath(_ id: String) -> String { keysDir + "/" + id + ".approve.pem" }

	/// What `RequestVerifier` needs for step 2 of §4.3.
	public func lookup(_ deviceID: String) -> DeviceLookup {
		guard LinkCrypto.isValidDeviceID(deviceID), let record = get(deviceID) else { return .unknown }
		if record.isRevoked { return .revoked }
		guard let key = try? LinkPublicKey(x963Base64: record.linkPubkey) else { return .unknown }
		return .active(key)
	}

	/// The non-revoked, owner-confirmed device whose `stt_key_sha256` matches, compared against
	/// every such device in constant time per comparison (§4.4).
	public func matchSTTKey(_ token: String) -> DeviceRecord? {
		guard !token.isEmpty else { return nil }
		let digest = Data(LinkCrypto.sha256Hex(Data(token.utf8)).utf8)
		var found: DeviceRecord?
		for device in active() where device.approveConfirmed && !device.sttKeySHA256.isEmpty {
			if Self.constantTimeEqual(digest, Data(device.sttKeySHA256.utf8)) { found = device }
		}
		return found
	}

	static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
		guard a.count == b.count else { return false }
		var diff: UInt8 = 0
		for (x, y) in zip(a, b) { diff |= x ^ y }
		return diff == 0
	}

	public func add(
		name: String, link: LinkPublicKey, approve: LinkPublicKey, sttKeySHA256: String,
		apns: DeviceRecord.APNs?, app: [String: String]?
	) throws -> DeviceRecord {
		lock.lock()
		defer { lock.unlock() }
		var id = LinkCrypto.newDeviceID()
		while devices[id] != nil { id = LinkCrypto.newDeviceID() }
		try FileStore.ensureDirectory(keysDir)
		try FileStore.writeAtomic(Data(link.spkiPEM.utf8), to: linkPEMPath(id))
		try FileStore.writeAtomic(Data(approve.spkiPEM.utf8), to: approvePEMPath(id))
		let record = DeviceRecord(
			deviceID: id, name: name, link: link, approve: approve, sttKeySHA256: sttKeySHA256, apns: apns,
			app: app,
			now: clock())
		devices[id] = record
		try save()
		return record
	}

	/// What `pinAccountDevice` did.
	public struct PinResult: Sendable {
		public var record: DeviceRecord
		/// A record was created for an id seen for the first time.
		public var isNew: Bool
		/// A known id came back with a different link, approve or agreement key: the record now
		/// holds the new keys and starts unconfirmed again, without an STT key.
		public var keyChanged: Bool
	}

	/// What a device name from the account may hold: no control, bidi, zero-width or line
	/// separator characters (`CanonicalApproval.isUnsafe`), at most 64 characters.
	public static func sanitizedName(_ name: String) -> String {
		var scalars = String.UnicodeScalarView()
		scalars.append(contentsOf: name.unicodeScalars.filter { !CanonicalApproval.isUnsafe($0) })
		return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(64))
	}

	/// Pins a device of the Mac's account under its account `device_id` (step 11), unconfirmed
	/// and without an STT key. An existing record with the same link, approve and agreement keys
	/// is kept as it is (a revoked one stays revoked). Any key change for a known id makes it a
	/// new, unconfirmed device: keys replaced, confirmation and STT key dropped,
	/// `key_changed_at` set. Throws for an invalid id or a clash with a code-paired record.
	public func pinAccountDevice(
		deviceID: String, name: String, link: LinkPublicKey, approve: LinkPublicKey, kem: LinkPublicKey
	) throws -> PinResult {
		lock.lock()
		defer { lock.unlock() }
		guard LinkCrypto.isValidDeviceID(deviceID) else {
			throw APIError(400, "bad_request", "invalid account device id")
		}
		let name = Self.sanitizedName(name)
		var keyChanged = false
		if let existing = devices[deviceID] {
			guard existing.origin == .account else {
				throw APIError(409, "conflict", "device id belongs to a code-paired device")
			}
			if existing.linkPubkey == link.x963Base64 && existing.approvePubkey == approve.x963Base64
				&& existing.kemPubkey == kem.x963Base64
			{
				if !existing.isRevoked, existing.name != name, !name.isEmpty {
					var renamed = existing
					renamed.name = name
					devices[deviceID] = renamed
					try save()
					return PinResult(record: renamed, isNew: false, keyChanged: false)
				}
				return PinResult(record: existing, isNew: false, keyChanged: false)
			}
			if existing.isRevoked { return PinResult(record: existing, isNew: false, keyChanged: false) }
			keyChanged = true
		}
		try FileStore.ensureDirectory(keysDir)
		try FileStore.writeAtomic(Data(link.spkiPEM.utf8), to: linkPEMPath(deviceID))
		try FileStore.writeAtomic(Data(approve.spkiPEM.utf8), to: approvePEMPath(deviceID))
		var record = DeviceRecord(
			deviceID: deviceID, name: name.isEmpty ? "iPhone" : name, link: link, approve: approve,
			sttKeySHA256: "", apns: nil, app: nil, now: clock(), approveConfirmed: false,
			origin: .account)
		record.kemPubkey = kem.x963Base64
		if keyChanged, let existing = devices[deviceID] {
			record.createdAt = existing.createdAt
			record.pushText = existing.pushText
			record.keyChangedAt = clock()
		}
		devices[deviceID] = record
		try save()
		return PinResult(record: record, isNew: !keyChanged, keyChanged: keyChanged)
	}

	/// Replaces the device's STT key hash (a re-sent link offer carries a fresh key).
	public func setSTTKeySHA256(_ deviceID: String, _ sha256: String) throws {
		lock.lock()
		defer { lock.unlock() }
		guard var record = devices[deviceID] else { return }
		record.sttKeySHA256 = sha256
		devices[deviceID] = record
		try save()
	}

	/// Marks the device confirmed by the owner, when `matches` accepts the record as it is now
	/// (checked under the registry lock, so keys cannot change between check and confirm).
	/// Nil if unknown or revoked; throws 409 `keys_changed` when `matches` refuses.
	@discardableResult
	public func confirmApprove(_ deviceID: String, matches: (DeviceRecord) -> Bool = { _ in true }) throws
		-> DeviceRecord?
	{
		lock.lock()
		defer { lock.unlock() }
		guard var record = devices[deviceID], !record.isRevoked else { return nil }
		guard matches(record) else {
			throw APIError(
				409, "keys_changed", "the device's keys changed since this safety number was shown; check again")
		}
		if !record.approveConfirmed || record.keyChangedAt != nil {
			record.approveConfirmed = true
			record.keyChangedAt = nil
			devices[deviceID] = record
			try save()
		}
		return record
	}

	/// Active devices waiting for the owner's confirmation.
	public func pendingApproveConfirmations() -> [DeviceRecord] {
		active().filter { !$0.approveConfirmed }
	}

	/// Marks the device revoked (kept for audit) and runs the revoke hooks. Nil if unknown.
	@discardableResult
	public func revoke(_ deviceID: String) -> DeviceRecord? {
		lock.lock()
		guard var record = devices[deviceID] else {
			lock.unlock()
			return nil
		}
		if record.revokedAt == nil {
			record.revokedAt = clock()
			devices[deviceID] = record
			try? save()
		}
		let hooks = revokeHooks
		lock.unlock()
		for hook in hooks { hook(deviceID) }
		return record
	}

	/// Updates `last_seen_at` at most once per 60 s per device.
	public func touch(_ deviceID: String) {
		lock.lock()
		defer { lock.unlock() }
		let now = clock()
		guard var record = devices[deviceID], now - record.lastSeenAt >= Self.lastSeenMinInterval else { return }
		record.lastSeenAt = now
		devices[deviceID] = record
		try? save()
	}

	public func setAPNs(_ deviceID: String, token: String?, env: String?) throws -> DeviceRecord? {
		lock.lock()
		defer { lock.unlock() }
		guard var record = devices[deviceID] else { return nil }
		record.apns = token.map { DeviceRecord.APNs(token: $0, env: env, updatedAt: clock()) }
		devices[deviceID] = record
		try save()
		return record
	}

	/// Sets what approval pushes to the device say. Nil if unknown.
	public func setPushText(_ deviceID: String, _ mode: PushTextMode) throws -> DeviceRecord? {
		lock.lock()
		defer { lock.unlock() }
		guard var record = devices[deviceID] else { return nil }
		if record.pushText != mode {
			record.pushText = mode
			devices[deviceID] = record
			try save()
		}
		return record
	}

	public func clearAPNs(_ deviceID: String) {
		_ = try? setAPNs(deviceID, token: nil, env: nil)
	}

	static func isValidAPNsToken(_ token: String) -> Bool {
		(64...200).contains(token.utf8.count) && token.utf8.allSatisfy { isxdigit(Int32($0)) != 0 }
	}
}
