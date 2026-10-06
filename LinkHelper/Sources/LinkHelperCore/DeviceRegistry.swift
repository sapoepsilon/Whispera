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
	}

	init(
		deviceID: String, name: String, link: LinkPublicKey, approve: LinkPublicKey, sttKeySHA256: String,
		apns: APNs?, app: [String: String]?, now: Int
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

	/// The non-revoked device whose `stt_key_sha256` matches, compared against every device in
	/// constant time per comparison (§4.4).
	public func matchSTTKey(_ token: String) -> DeviceRecord? {
		guard !token.isEmpty else { return nil }
		let digest = Data(LinkCrypto.sha256Hex(Data(token.utf8)).utf8)
		var found: DeviceRecord?
		for device in active() {
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

	public func clearAPNs(_ deviceID: String) {
		_ = try? setAPNs(deviceID, token: nil, env: nil)
	}

	static func isValidAPNsToken(_ token: String) -> Bool {
		(64...200).contains(token.utf8.count) && token.utf8.allSatisfy { isxdigit(Int32($0)) != 0 }
	}
}
