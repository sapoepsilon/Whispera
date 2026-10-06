import Foundation
import WhisperaLink
import WhisperaLinkServer

/// Pairing codes and `POST /v1/pair` (PROTOCOL §3). Codes live in memory only; at most one
/// live code; single use; TTL; five failed attempts burn it.
public final class PairingManager: @unchecked Sendable {
	static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")
	static let maxFails = 5

	private final class Code {
		enum State { case live, used, locked, superseded }
		let code: String
		let expiresAt: Int
		var fails = 0
		var state = State.live
		var device: [String: Any]?

		init(code: String, expiresAt: Int) {
			self.code = code
			self.expiresAt = expiresAt
		}
	}

	private let devices: DeviceRegistry
	private let daemonKey: SoftwareSigningKey
	public let daemonFP: String
	private let publicURL: @Sendable () -> String
	private let defaultTTL: Int
	private let clock: @Sendable () -> Int
	private let log: OpsLog
	private let condition = NSCondition()
	private var current: Code?

	public init(
		devices: DeviceRegistry, daemonKey: SoftwareSigningKey, publicURL: @escaping @Sendable () -> String,
		defaultTTL: Int = 300, clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
		log: OpsLog = .null
	) {
		self.devices = devices
		self.daemonKey = daemonKey
		daemonFP = LinkPublicKey(daemonKey.privateKey.publicKey).fingerprint
		self.publicURL = publicURL
		self.defaultTTL = defaultTTL
		self.clock = clock
		self.log = log
	}

	static func newCode() -> String {
		var generator = SystemRandomNumberGenerator()
		return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
	}

	static func normalize(_ code: String) -> String {
		code.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
	}

	static func qrPayload(url: String, code: String, fingerprint: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
		return "whispera-link://pair?v=1&url=\(encoded)&code=\(code)&fp=\(fingerprint)"
	}

	// MARK: Owner side (admin socket)

	public func begin(ttl requested: Int?) -> [String: Any] {
		let ttl = max(10, min(requested ?? defaultTTL, 3600))
		condition.lock()
		if let live = current, live.state == .live { live.state = .superseded }
		let code = Code(code: Self.newCode(), expiresAt: clock() + ttl)
		current = code
		condition.broadcast()
		condition.unlock()
		let url = publicURL()
		log("pair.begin", ["detail": "ttl=\(ttl)"])
		return [
			"ok": true, "code": String(code.code.prefix(4)) + "-" + String(code.code.suffix(4)),
			"expires_at": code.expiresAt, "daemon_fp": daemonFP, "url": url,
			"qr_payload": Self.qrPayload(url: url, code: code.code, fingerprint: daemonFP),
		]
	}

	/// Blocks until the code is used (the public device record) or dies (throws).
	public func wait(code raw: String, timeout: Double) throws -> [String: Any] {
		let code = Self.normalize(raw)
		let deadline = Date().addingTimeInterval(max(0, timeout))
		condition.lock()
		defer { condition.unlock() }
		guard let entry = current, entry.code == code else {
			throw APIError(403, "pair_code_invalid", "no such pairing code")
		}
		while true {
			switch entry.state {
			case .used: return entry.device ?? [:]
			case .locked: throw APIError(429, "pair_locked", "too many failed attempts; code burned")
			case .superseded: throw APIError(410, "pair_code_expired", "pairing code was replaced by a newer one")
			case .live: break
			}
			if clock() >= entry.expiresAt { throw APIError(410, "pair_code_expired", "pairing code expired") }
			if Date() >= deadline {
				throw APIError(504, "pair_wait_timeout", "no phone paired before the wait timeout")
			}
			_ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.5)))
		}
	}

	public var isLive: Bool {
		condition.lock()
		defer { condition.unlock() }
		guard let entry = current else { return false }
		return entry.state == .live && clock() < entry.expiresAt
	}

	// MARK: Phone side

	/// `POST /v1/pair`. Returns the 201 body bytes and the server signature header value.
	public func handlePair(_ body: Data) throws -> (Data, String) {
		guard let request = WireJSON.decodeObject(body) else {
			throw APIError(400, "bad_request", "body is not valid JSON")
		}
		let code = Self.normalize(request["code"] as? String ?? "")
		let record: DeviceRecord
		let sttKey: String
		condition.lock()
		do {
			defer { condition.unlock() }
			let candidate = current
			if let candidate, candidate.state == .locked, code == candidate.code {
				throw APIError(429, "pair_locked", "too many failed attempts; code burned")
			}
			guard let entry = candidate, entry.state == .live,
				DeviceRegistry.constantTimeEqual(Data(code.utf8), Data(entry.code.utf8))
			else {
				if let candidate, candidate.state == .live {
					candidate.fails += 1
					if candidate.fails >= Self.maxFails {
						candidate.state = .locked
						condition.broadcast()
						log("pair.locked")
						throw APIError(429, "pair_locked", "too many failed attempts; code burned")
					}
				}
				log("pair.fail", ["detail": "code_invalid"])
				throw APIError(403, "pair_code_invalid", "pairing code is wrong or not active")
			}
			if clock() >= entry.expiresAt { throw APIError(410, "pair_code_expired", "pairing code expired") }

			guard WireJSON.strictInt(request["v"]) == 1 else { throw APIError(400, "bad_request", "v must be 1") }
			guard let name = request["name"] as? String, (1...64).contains(name.count),
				name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
			else { throw APIError(400, "bad_request", "name must be 1-64 printable characters") }
			let link: LinkPublicKey
			let approve: LinkPublicKey
			do {
				link = try LinkPublicKey(x963Base64: request["link_pubkey"] as? String ?? "")
				approve = try LinkPublicKey(x963Base64: request["approve_pubkey"] as? String ?? "")
			} catch {
				throw APIError(400, "bad_request", "public keys must be 65-byte X9.63 P-256 points")
			}
			guard link != approve else { throw APIError(400, "bad_request", "link and approve keys must differ") }
			var apns: DeviceRecord.APNs?
			if let rawAPNs = request["apns"], !(rawAPNs is NSNull) {
				guard let object = rawAPNs as? [String: Any] else {
					throw APIError(400, "bad_request", "apns must be an object or null")
				}
				let token = object["token"]
				let env = object["env"]
				if let token, !(token is NSNull),
					!((token as? String).map(DeviceRegistry.isValidAPNsToken) ?? false)
				{
					throw APIError(400, "bad_request", "apns.token must be 64-200 hex chars")
				}
				if let env, !(env is NSNull), !((env as? String).map(DeviceRegistry.apnsEnvs.contains) ?? false)
				{
					throw APIError(400, "bad_request", "apns.env must be sandbox or production")
				}
				if let token = token as? String, !token.isEmpty {
					apns = .init(token: token.lowercased(), env: env as? String, updatedAt: clock())
				}
			}
			var app: [String: String]?
			if let rawApp = request["app"], !(rawApp is NSNull) {
				guard let object = rawApp as? [String: Any] else {
					throw APIError(400, "bad_request", "app must be an object")
				}
				app = [
					"bundle_id": String("\(object["bundle_id"] ?? "")".prefix(128)),
					"version": String("\(object["version"] ?? "")".prefix(64)),
				]
			}
			guard let proofB64 = request["proof"] as? String,
				let approveProofB64 = request["approve_proof"] as? String
			else { throw APIError(422, "bad_signature", "proof and approve_proof are required") }
			let proof = Data(base64Encoded: proofB64) ?? Data()
			let approveProof = Data(base64Encoded: approveProofB64) ?? Data()
			guard
				LinkSignatures.verifyPairingProofs(
					code: entry.code, daemonFP: daemonFP, linkKey: link, approveKey: approve, proof: proof,
					approveProof: approveProof)
			else {
				log("pair.fail", ["detail": "bad_signature"])
				throw APIError(422, "bad_signature", "pairing proof does not verify")
			}

			sttKey = "wlk_" + LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
			record = try devices.add(
				name: name, link: link, approve: approve, sttKeySHA256: LinkCrypto.sha256Hex(Data(sttKey.utf8)),
				apns: apns,
				app: app)
			entry.state = .used
			entry.device = record.publicJSON
			condition.broadcast()
		}

		let url = publicURL()
		let response: [String: Any] = [
			"device_id": record.deviceID,
			"daemon_pubkey": LinkPublicKey(daemonKey.privateKey.publicKey).x963Base64,
			"daemon_fp": daemonFP,
			"approve_fp": record.approveFP,
			"stt_key": sttKey,
			"stt_base_url": url + "/v1",
			"server_time": clock(),
		]
		let out = WireJSON.encode(response)
		let signature = try LinkSignatures.signPairResponse(out, daemonKey: daemonKey)
		log("pair.ok", ["device": record.deviceID])
		return (out, signature)
	}
}
