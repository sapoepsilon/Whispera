import Foundation

/// What the Mac's QR code (or the manual form) carries (§3.2).
public struct PairingPayload: Equatable, Sendable {
	public var baseURL: URL
	public var code: String
	/// The daemon key fingerprint, when the QR carried one; nil for a manual entry.
	public var fingerprint: String?

	public init(baseURL: URL, code: String, fingerprint: String?) {
		self.baseURL = baseURL
		self.code = code
		self.fingerprint = fingerprint
	}

	public static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

	public static func normalizeCode(_ raw: String) -> String {
		raw.uppercased().filter { $0 != "-" && !$0.isWhitespace }
	}

	public static func isValidCode(_ code: String) -> Bool {
		code.count == 8 && code.allSatisfy { alphabet.contains($0) }
	}

	/// `whispera-link://pair?v=1&url=<pct url>&code=<8>&fp=<64 hex>` (§3.2).
	public static func parse(qr: String) -> PairingPayload? {
		guard let components = URLComponents(string: qr.trimmingCharacters(in: .whitespacesAndNewlines)),
			  components.scheme == "whispera-link", components.host == "pair"
		else { return nil }
		let items = Dictionary(
			(components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
		guard items["v"] == "1",
			  let urlString = items["url"], let url = URL(string: urlString),
			  url.scheme == "http" || url.scheme == "https",
			  let rawCode = items["code"], let fp = items["fp"]?.lowercased(),
			  fp.count == 64, fp.allSatisfy({ $0.isHexDigit })
		else { return nil }
		let code = normalizeCode(rawCode)
		guard isValidCode(code) else { return nil }
		return PairingPayload(baseURL: url, code: code, fingerprint: fp)
	}

	public static func manual(url raw: String, code rawCode: String) -> PairingPayload? {
		var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if !text.contains("://") { text = "http://" + text }
		guard let url = URL(string: text), url.host != nil else { return nil }
		let code = normalizeCode(rawCode)
		guard isValidCode(code) else { return nil }
		return PairingPayload(baseURL: url, code: code, fingerprint: nil)
	}
}

/// What a successful pairing leaves behind, stored in the Keychain
/// (`AfterFirstUnlockThisDeviceOnly`).
public struct PairingRecord: Codable, Equatable, Sendable {
	public var deviceID: String
	public var baseURL: URL
	public var daemonPubkeyB64: String
	public var daemonFP: String
	public var approveFP: String
	public var sttKey: String
	public var sttBaseURL: URL
	public var name: String
	public var pairedAt: Date
	public var demo: Bool = false

	public init(
		deviceID: String, baseURL: URL, daemonPubkeyB64: String, daemonFP: String, approveFP: String, sttKey: String,
		sttBaseURL: URL, name: String, pairedAt: Date, demo: Bool = false
	) {
		self.deviceID = deviceID
		self.baseURL = baseURL
		self.daemonPubkeyB64 = daemonPubkeyB64
		self.daemonFP = daemonFP
		self.approveFP = approveFP
		self.sttKey = sttKey
		self.sttBaseURL = sttBaseURL
		self.name = name
		self.pairedAt = pairedAt
		self.demo = demo
	}

	public var daemonPubkey: Data { Data(base64Encoded: daemonPubkeyB64) ?? Data() }

	public static let account = "pairing"

	/// Reads the record stored next to `keys`.
	public static func load(from keys: DeviceKeys) -> PairingRecord? {
		guard let data = try? keys.keychain.get(account: account) else { return nil }
		return try? JSONDecoder().decode(PairingRecord.self, from: data)
	}

	public func save(to keys: DeviceKeys) throws {
		try keys.keychain.set(try JSONEncoder().encode(self), account: Self.account)
	}

	public static func clear(from keys: DeviceKeys) {
		try? keys.keychain.delete(account: account)
	}
}

public enum PairingError: LocalizedError {
	case tampered
	case badResponse(String)
	case fingerprintMismatch
	/// Manual pairing: the owner said the Mac's fingerprint on the phone is not the one the
	/// Mac shows. Nothing secret was sent.
	case fingerprintRejected

	public var errorDescription: String? {
		switch self {
		case .tampered, .fingerprintMismatch:
			return "Pairing was tampered with or the code is wrong"
		case .fingerprintRejected:
			return "The Mac's fingerprint didn't match. Nothing was sent; try again on a network you trust."
		case .badResponse(let detail):
			return "Unexpected pairing response: \(detail)"
		}
	}
}

public struct PairingOutcome: Sendable {
	public var record: PairingRecord
	/// Always false since pairing v2: a manual pairing has the owner compare the Mac's
	/// fingerprint *before* the code is revealed (`confirmFingerprint`).
	public var needsManualFingerprintCheck: Bool

	public init(record: PairingRecord, needsManualFingerprintCheck: Bool) {
		self.record = record
		self.needsManualFingerprintCheck = needsManualFingerprintCheck
	}
}

/// §3.3 phone side, pairing v2 (commit, then reveal):
///
/// 1. Fix the daemon fingerprint: the QR's, or (manual entry) the one `/v1/health` names.
/// 2. Make the keys and proofs, then send only a commitment to (code, daemon fp, both
///    keys, a secret nonce) to `POST /v1/pair/commit`.
/// 3. Check the acknowledgement: signed by a daemon key whose fingerprint is the one fixed
///    in step 1, echoing our commitment. A manual entry also has the owner compare that
///    fingerprint with the Mac's screen (`confirmFingerprint`) here.
/// 4. Only then reveal the code, nonce and keys in `POST /v1/pair`.
///
/// An on-path attacker that reads the reveal learns a code the daemon has already bound
/// to this phone's commitment; the daemon takes one commitment per code, so the code is
/// worth nothing to it. On any failure the freshly made keys in `keys` are deleted.
///
/// `keyMaker` and `approveMaker` default to making real keys in `keys` (the approve key
/// under `approvePolicy`); tests pass software keys instead.
public enum PairingService {
	public static func pair(
		_ payload: PairingPayload,
		name: String,
		apns: (token: String, env: String)?,
		keys: DeviceKeys,
		transport: LinkTransport = URLSessionLinkTransport(),
		keyMaker: (@Sendable () throws -> LinkSigningKey)? = nil,
		approveMaker: (@Sendable (Data) async throws -> (LinkSigningKey, Data))? = nil,
		approveReason: String = "Create the approval key for your Mac",
		approvePolicy: ApproveKeyPolicy = .userPresence,
		confirmFingerprint: (@Sendable (String) async -> Bool)? = nil,
		nonceMaker: @Sendable () -> Data = { LinkCrypto.randomBytes(32) }
	) async throws -> PairingOutcome {
		let keyMaker = keyMaker ?? { try keys.create(.link) }
		let approveMaker = approveMaker ?? { message in
			try await keys.createApproveKeyAndProve(message, reason: approveReason, policy: approvePolicy)
		}
		// A manual entry has no QR fingerprint; without a way to ask the owner it cannot be
		// made safe, so refuse before anything is sent.
		if payload.fingerprint == nil, confirmFingerprint == nil {
			throw PairingError.badResponse("manual pairing needs a fingerprint check")
		}
		let daemonFP: String
		if let fp = payload.fingerprint {
			daemonFP = fp
		} else {
			daemonFP = try await LinkClient.health(baseURL: payload.baseURL, transport: transport).daemon_fp.lowercased()
		}
		do {
			let linkKey = try keyMaker()
			let approveMessage = LinkCrypto.pairApproveMessage(code: payload.code, daemonFP: daemonFP)
			let (approveKey, approveProof) = try await approveMaker(approveMessage)
			let proof = try linkKey.sign(
				LinkCrypto.pairProofMessage(code: payload.code, daemonFP: daemonFP, approveX963: approveKey.publicKeyX963))
			let nonce = nonceMaker()
			let commitment = LinkCrypto.pairCommitment(
				code: payload.code, daemonFP: daemonFP, linkX963: linkKey.publicKeyX963,
				approveX963: approveKey.publicKeyX963, nonce: nonce)

			// Commit: nothing that could pair a device is in this request.
			let (ackData, ackResponse) = try await post(
				payload.baseURL, "/v1/pair/commit", ["v": 2, "commitment": commitment], transport: transport)
			let ack: PairCommitAck
			do {
				ack = try JSONDecoder().decode(PairCommitAck.self, from: ackData)
			} catch {
				throw PairingError.badResponse("\(error)")
			}
			guard let daemonKey = Data(base64Encoded: ack.daemon_pubkey), LinkCrypto.isValidX963(daemonKey) else {
				throw PairingError.tampered
			}
			let computedFP = LinkCrypto.fingerprint(x963: daemonKey)
			guard computedFP == daemonFP, ack.daemon_fp.lowercased() == computedFP else {
				throw PairingError.fingerprintMismatch
			}
			guard let ackSigB64 = ackResponse.value(forHTTPHeaderField: SignedHeaders.serverSignatureHeader),
				  let ackSignature = Data(base64Encoded: ackSigB64),
				  LinkCrypto.verify(
					x963: daemonKey, message: LinkCrypto.pairCommitAckMessage(body: ackData), derSignature: ackSignature),
				  ack.v == 2, ack.commitment.lowercased() == commitment
			else { throw PairingError.tampered }
			if payload.fingerprint == nil {
				guard let confirmFingerprint, await confirmFingerprint(LinkCrypto.displayFingerprint(computedFP)) else {
					throw PairingError.fingerprintRejected
				}
			}

			// Reveal.
			var body: [String: Any] = [
				"v": 2,
				"pair_id": ack.pair_id,
				"nonce": nonce.base64EncodedString(),
				"code": payload.code,
				"name": String(name.prefix(64)),
				"link_pubkey": linkKey.publicKeyX963.base64EncodedString(),
				"approve_pubkey": approveKey.publicKeyX963.base64EncodedString(),
				"proof": proof.base64EncodedString(),
				"approve_proof": approveProof.base64EncodedString(),
				"app": [
					"bundle_id": Bundle.main.bundleIdentifier ?? "com.chatgenie.Whispera",
					"version": appVersion,
				],
			]
			body["apns"] = apns.map { ["token": $0.token, "env": $0.env] } ?? NSNull()
			let (data, response) = try await post(payload.baseURL, "/v1/pair", body, transport: transport)
			let decoded: PairResponse
			do {
				decoded = try JSONDecoder().decode(PairResponse.self, from: data)
			} catch {
				throw PairingError.badResponse("\(error)")
			}
			guard decoded.daemon_pubkey == ack.daemon_pubkey, decoded.daemon_fp.lowercased() == computedFP else {
				throw PairingError.fingerprintMismatch
			}
			guard let sigB64 = response.value(forHTTPHeaderField: SignedHeaders.serverSignatureHeader),
				  let signature = Data(base64Encoded: sigB64),
				  LinkCrypto.verify(x963: daemonKey, message: LinkCrypto.pairResponseMessage(body: data), derSignature: signature)
			else { throw PairingError.tampered }
			guard decoded.approve_fp.lowercased() == LinkCrypto.fingerprint(x963: approveKey.publicKeyX963) else {
				throw PairingError.tampered
			}
			guard let sttBase = URL(string: decoded.stt_base_url) else {
				throw PairingError.badResponse("stt_base_url")
			}
			let record = PairingRecord(
				deviceID: decoded.device_id,
				baseURL: payload.baseURL,
				daemonPubkeyB64: decoded.daemon_pubkey,
				daemonFP: computedFP,
				approveFP: decoded.approve_fp.lowercased(),
				sttKey: decoded.stt_key,
				sttBaseURL: sttBase,
				name: name,
				pairedAt: Date())
			return PairingOutcome(record: record, needsManualFingerprintCheck: false)
		} catch {
			keys.deleteAll()
			throw error
		}
	}

	private static func post(
		_ baseURL: URL, _ path: String, _ body: [String: Any], transport: LinkTransport
	) async throws -> (Data, HTTPURLResponse) {
		var base = baseURL.absoluteString
		while base.hasSuffix("/") { base.removeLast() }
		var request = URLRequest(url: URL(string: base + path)!)
		request.httpMethod = "POST"
		request.timeoutInterval = LinkClient.defaultTimeout
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
		let data: Data
		let response: HTTPURLResponse
		do {
			(data, response) = try await transport.data(for: request)
		} catch {
			throw LinkError.transport(error)
		}
		guard response.statusCode == 201 || response.statusCode == 200 else {
			throw LinkError.decode(status: response.statusCode, body: data)
		}
		return (data, response)
	}

	public static var appVersion: String {
		let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
		let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
		return "\(short) (\(build))"
	}

}
