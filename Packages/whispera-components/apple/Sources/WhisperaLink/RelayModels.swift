import Foundation

// JSON bodies of the Whispera backend's device registry and relay. Each type mirrors
// one in the Rust `whispera_proto::wire` module (whispera-backend PR #4), same name
// and same snake_case fields:
//
// | Swift | Rust (`wire.rs`) |
// | --- | --- |
// | `Platform`, `ApnsEnv`, `ApnsRegistration` | same |
// | `RegisterDeviceRequest`, `PublicDevice`, `DeviceList` | same |
// | `UpdateApnsRequest` | same |
// | `RelaySendRequest` / `RelaySendResponse` | same |
// | `RelayMessage` / `RelayFetchResponse` | same |
// | `RelayAckRequest` / `RelayAckResponse` | same |
// | `NotifyRequest` / `NotifyResponse` | same |
// | `BackendHealth` | `Health` |
//
// `kem_pubkey` is opaque to the server (standard base64, 1–2048 bytes). This package
// fills it with a `KEMKeyRecord`: the agreement key plus the device's link-key
// signature over it, so the key a peer seals to is exactly as trustworthy as the
// link key that peer already pinned.

public enum Platform: String, Codable, Sendable, CaseIterable {
	case ios, macos, linux, other

	/// This build's platform.
	public static var current: Platform {
		#if os(iOS)
			return .ios
		#elseif os(macOS)
			return .macos
		#elseif os(Linux)
			return .linux
		#else
			return .other
		#endif
	}
}

public enum ApnsEnv: String, Codable, Sendable, CaseIterable {
	case sandbox, production
}

public struct ApnsRegistration: Codable, Equatable, Sendable {
	/// Hex device token.
	public var token: String
	public var env: ApnsEnv

	public init(token: String, env: ApnsEnv) {
		self.token = token
		self.env = env
	}
}

/// `POST /v1/devices` body.
public struct RegisterDeviceRequest: Codable, Equatable, Sendable {
	public var name: String
	public var platform: Platform
	/// X9.63 base64 link (request-signing) public key.
	public var link_pubkey: String
	public var approve_pubkey: String?
	/// Standard base64 of a `KEMKeyRecord` (`KEMKeyRecord.base64`).
	public var kem_pubkey: String?
	public var apns: ApnsRegistration?

	public init(
		name: String, platform: Platform, link_pubkey: String, approve_pubkey: String? = nil, kem_pubkey: String? = nil,
		apns: ApnsRegistration? = nil
	) {
		self.name = name
		self.platform = platform
		self.link_pubkey = link_pubkey
		self.approve_pubkey = approve_pubkey
		self.kem_pubkey = kem_pubkey
		self.apns = apns
	}

	// Omit nil optionals, as Rust's `skip_serializing_if = "Option::is_none"` does.
	enum CodingKeys: String, CodingKey { case name, platform, link_pubkey, approve_pubkey, kem_pubkey, apns }

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(name, forKey: .name)
		try c.encode(platform, forKey: .platform)
		try c.encode(link_pubkey, forKey: .link_pubkey)
		try c.encodeIfPresent(approve_pubkey, forKey: .approve_pubkey)
		try c.encodeIfPresent(kem_pubkey, forKey: .kem_pubkey)
		try c.encodeIfPresent(apns, forKey: .apns)
	}
}

/// `PUT /v1/device/apns` body: `{"apns":{"token","env"}}`, or `{"apns":null}` to clear.
public struct UpdateApnsRequest: Codable, Equatable, Sendable {
	public var apns: ApnsRegistration?

	public init(apns: ApnsRegistration?) {
		self.apns = apns
	}

	enum CodingKeys: String, CodingKey { case apns }

	// Always written, as `null` when clearing: an explicit null is what clears the token.
	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(apns, forKey: .apns)
	}
}

/// Last 8 chars of an APNs token, the only part ever shown publicly (`apns_token_suffix`).
public func apnsTokenSuffix(_ token: String) -> String {
	String(token.suffix(8))
}

/// A device as the backend shows it to the account's other devices (§3.4 public form).
public struct PublicDevice: Codable, Equatable, Sendable, Identifiable {
	public var device_id: String
	public var name: String
	public var platform: Platform
	public var link_pubkey: String
	public var approve_pubkey: String?
	public var kem_pubkey: String?
	public var link_fp: String
	public var approve_fp: String?
	/// Last 8 chars of the APNs token only.
	public var apns_token_suffix: String?
	public var apns_env: ApnsEnv?
	public var created_at: Int64
	public var revoked_at: Int64?

	public init(
		device_id: String, name: String, platform: Platform, link_pubkey: String, approve_pubkey: String? = nil,
		kem_pubkey: String? = nil, link_fp: String, approve_fp: String? = nil,
		apns_token_suffix: String? = nil, apns_env: ApnsEnv? = nil, created_at: Int64, revoked_at: Int64? = nil
	) {
		self.device_id = device_id
		self.name = name
		self.platform = platform
		self.link_pubkey = link_pubkey
		self.approve_pubkey = approve_pubkey
		self.kem_pubkey = kem_pubkey
		self.link_fp = link_fp
		self.approve_fp = approve_fp
		self.apns_token_suffix = apns_token_suffix
		self.apns_env = apns_env
		self.created_at = created_at
		self.revoked_at = revoked_at
	}

	public var id: String { device_id }

	public var isRevoked: Bool { revoked_at != nil }

	/// The link key, after checking it matches the advertised fingerprint — a
	/// device list is only as good as the keys it pins.
	public func verifiedLinkKey() throws -> LinkPublicKey {
		let key = try LinkPublicKey(x963Base64: link_pubkey)
		guard key.fingerprint == link_fp.lowercased() else { throw RelayError.fingerprintMismatch(device_id) }
		return key
	}

	/// The agreement key from `kem_pubkey`, after checking its link-key signature
	/// against this record's (fingerprint-checked) link key. Nil when the device has
	/// published none.
	public func verifiedAgreementKey() throws -> LinkPublicKey? {
		guard let kem_pubkey else { return nil }
		return try KEMKeyRecord(base64: kem_pubkey).verifiedKey(linkKey: try verifiedLinkKey())
	}
}

public struct DeviceList: Codable, Equatable, Sendable {
	public var devices: [PublicDevice]

	public init(devices: [PublicDevice]) {
		self.devices = devices
	}
}

public struct RelaySendRequest: Codable, Equatable, Sendable {
	/// Recipient device id.
	public var to: String
	/// Base64 opaque sealed envelope (`SealedEnvelope.base64`).
	public var ciphertext: String
	public var ttl_s: UInt32?

	public init(to: String, ciphertext: String, ttl_s: UInt32? = nil) {
		self.to = to
		self.ciphertext = ciphertext
		self.ttl_s = ttl_s
	}

	enum CodingKeys: String, CodingKey { case to, ciphertext, ttl_s }

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(to, forKey: .to)
		try c.encode(ciphertext, forKey: .ciphertext)
		try c.encodeIfPresent(ttl_s, forKey: .ttl_s)
	}
}

public struct RelaySendResponse: Codable, Equatable, Sendable {
	public var seq: Int64
	public var expires_at: Int64

	public init(seq: Int64, expires_at: Int64) {
		self.seq = seq
		self.expires_at = expires_at
	}
}

public struct RelayMessage: Codable, Equatable, Sendable {
	public var seq: Int64
	/// Sender device id.
	public var from: String
	public var ciphertext: String
	public var expires_at: Int64
	public var created_at: Int64

	public init(seq: Int64, from: String, ciphertext: String, expires_at: Int64, created_at: Int64) {
		self.seq = seq
		self.from = from
		self.ciphertext = ciphertext
		self.expires_at = expires_at
		self.created_at = created_at
	}
}

public struct RelayFetchResponse: Codable, Equatable, Sendable {
	public var messages: [RelayMessage]

	public init(messages: [RelayMessage]) {
		self.messages = messages
	}
}

public struct RelayAckRequest: Codable, Equatable, Sendable {
	public var up_to_seq: Int64

	public init(up_to_seq: Int64) {
		self.up_to_seq = up_to_seq
	}
}

public struct RelayAckResponse: Codable, Equatable, Sendable {
	/// How many messages the ack removed.
	public var deleted: UInt64

	public init(deleted: UInt64) {
		self.deleted = deleted
	}
}

/// `POST /v1/notify` body. Without `kind` it is the legacy content-free push.
public struct NotifyRequest: Codable, Equatable, Sendable {
	public var device_id: String
	/// `"approval"` | `"approval.resolved"` (`NotifyKind`).
	public var kind: String?
	/// `apr_[a-z0-9]{8,64}`.
	public var request_id: String?
	/// WLP1 blob (`PushSealing`), standard base64 ≤ 2048 chars; only with `approval`.
	public var sealed: String?

	public init(device_id: String, kind: String? = nil, request_id: String? = nil, sealed: String? = nil) {
		self.device_id = device_id
		self.kind = kind
		self.request_id = request_id
		self.sealed = sealed
	}

	enum CodingKeys: String, CodingKey { case device_id, kind, request_id, sealed }

	// Omit nil optionals: the server rejects unknown fields and needs none of these.
	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(device_id, forKey: .device_id)
		try c.encodeIfPresent(kind, forKey: .kind)
		try c.encodeIfPresent(request_id, forKey: .request_id)
		try c.encodeIfPresent(sealed, forKey: .sealed)
	}
}

public enum NotifyKind: String, Codable, Sendable, CaseIterable {
	case approval
	case approvalResolved = "approval.resolved"
}

public struct NotifyResponse: Codable, Equatable, Sendable {
	/// `"sent" | "unconfigured" | "no_token" | "failed"`.
	public var push: String

	public static let sent = "sent"
	public static let unconfigured = "unconfigured"
	public static let noToken = "no_token"
	public static let failed = "failed"

	public init(push: String) {
		self.push = push
	}
}

/// `GET /v1/health` on the backend. Rust: `Health`.
public struct BackendHealth: Codable, Equatable, Sendable {
	public var ok: Bool
	public var service: String
	public var version: String
	public var `protocol`: UInt32
	public var server_time: Int64
	public var apns: String

	public init(ok: Bool, service: String, version: String, protocol: UInt32, server_time: Int64, apns: String) {
		self.ok = ok
		self.service = service
		self.version = version
		self.protocol = `protocol`
		self.server_time = server_time
		self.apns = apns
	}
}

/// What a device publishes as `kem_pubkey`: its relay agreement key, signed by its
/// link key so a server cannot swap one in.
///
/// Bytes (then standard base64): the 65-byte X9.63 P-256 agreement key, followed by
/// an ECDSA P-256 / SHA-256 DER signature by the device's link key over
/// `"WL1-KEM\n" ‖ x963`.
public struct KEMKeyRecord: Equatable, Sendable {
	public static let context = Data("WL1-KEM\n".utf8)

	public let key: LinkPublicKey
	public let signature: Data

	public init(key: LinkPublicKey, signature: Data) {
		self.key = key
		self.signature = signature
	}

	public static func sign(_ key: LinkPublicKey, linkKey: LinkSigningKey) throws -> KEMKeyRecord {
		KEMKeyRecord(key: key, signature: try linkKey.sign(context + key.x963))
	}

	public var serialized: Data { key.x963 + signature }
	public var base64: String { serialized.base64EncodedString() }

	public init(base64: String) throws {
		guard let data = Data(base64Encoded: base64), data.count > LinkCrypto.x963Length,
		      let key = try? LinkPublicKey(x963: data.prefix(LinkCrypto.x963Length))
		else { throw RelayError.badKEMRecord }
		self.key = key
		signature = Data(data.dropFirst(LinkCrypto.x963Length))
	}

	/// The key, if `linkKey` signed it.
	public func verifiedKey(linkKey: LinkPublicKey) throws -> LinkPublicKey {
		guard linkKey.isValidSignature(signature, for: Self.context + key.x963) else { throw RelayError.badKEMRecord }
		return key
	}
}
