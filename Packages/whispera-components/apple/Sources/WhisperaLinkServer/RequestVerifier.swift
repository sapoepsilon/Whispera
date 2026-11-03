import Foundation
import WhisperaLink

/// What the server knows about a device id.
public enum DeviceLookup: Sendable, Equatable {
	case active(LinkPublicKey)
	case revoked
	case unknown
}

/// A request that passed every check, with the device it came from.
public struct VerifiedRequest: Sendable, Equatable {
	public var deviceID: String
	public var nonce: String
	public var timestamp: Int64

	public init(deviceID: String, nonce: String, timestamp: Int64) {
		self.deviceID = deviceID
		self.nonce = nonce
		self.timestamp = timestamp
	}
}

/// A refusal: the code, the constant text, and `server_time` when the client needs it
/// to fix its clock. `envelope` is the body to send, `httpStatus` the status.
public struct VerificationFailure: Error, Sendable, Equatable {
	public var code: ErrorCode
	public var serverTime: Int64?

	public init(code: ErrorCode, serverTime: Int64? = nil) {
		self.code = code
		self.serverTime = serverTime
	}

	public var httpStatus: Int { code.httpStatus }

	/// Constant text per code (§4.3): a refusal never says which byte was wrong.
	public var message: String {
		switch code {
		case .authMissing: return "missing X-WL-* auth headers"
		case .authUnknownDevice: return "unknown device"
		case .authRevoked: return "device revoked"
		case .authClockSkew: return "timestamp outside the allowed clock skew"
		case .payloadTooLarge: return "request body too large"
		case .authBadSignature: return "bad request signature"
		case .authReplay: return "nonce already used"
		default: return code.rawValue
		}
	}

	public var envelope: ErrorEnvelope {
		ErrorEnvelope(code, message: message, serverTime: code == .authClockSkew ? serverTime : nil)
	}
}

/// The receiving side of WL1 (PROTOCOL §4.3), for the Mac helper and anything else
/// that accepts signed requests. Fails closed, in the protocol's order:
///
/// 1. all four `X-WL-*` headers present → `auth_missing`
/// 2. device known → `auth_unknown_device`; not revoked → `auth_revoked`
/// 3. `|now − ts| ≤ skew` → `auth_clock_skew` (with `server_time`)
/// 4. body within the route limit → `payload_too_large`
/// 5. signature verifies with the device's link key → `auth_bad_signature`
/// 6. `(device, nonce)` unseen → `auth_replay`; then remembered
///
/// The nonce is only remembered once the signature has verified, so nobody can burn
/// a legitimate client's nonce by sending garbage under it.
public struct RequestVerifier: Sendable {
	public let skew: Int64
	public let replayCache: ReplayCache
	private let lookup: @Sendable (String) -> DeviceLookup

	public init(
		skew: Int64 = Int64(LinkCrypto.defaultClockSkew),
		replayCache: ReplayCache = ReplayCache(),
		lookup: @escaping @Sendable (String) -> DeviceLookup
	) {
		self.skew = skew
		self.replayCache = replayCache
		self.lookup = lookup
	}

	/// - Parameters:
	///   - target: the request target exactly as it arrived on the request line —
	///     path plus `?query`, percent-encoding untouched.
	///   - headers: request headers; names are matched case-insensitively.
	///   - maxBodyBytes: the route's body limit (§5.0); nil for none.
	public func verify(
		method: String, target: String, headers: [String: String], body: Data, now: Int64,
		maxBodyBytes: Int? = nil
	) -> Result<VerifiedRequest, VerificationFailure> {
		guard let signed = SignedHeaders(headers: headers) else { return .failure(.init(code: .authMissing)) }
		let key: LinkPublicKey
		switch lookup(signed.deviceID) {
		case .unknown: return .failure(.init(code: .authUnknownDevice))
		case .revoked: return .failure(.init(code: .authRevoked))
		case .active(let found): key = found
		}
		guard let ts = LinkCrypto.parseTimestamp(signed.timestamp) else {
			return .failure(.init(code: .authClockSkew, serverTime: now))
		}
		if let maxBodyBytes, body.count > maxBodyBytes {
			// Skew first, as §4.3 orders it: a stale client learns its clock is off
			// before learning its body is too big.
			if case .failure(let code) = signed.verifyClock(now: now, skew: skew) {
				return .failure(.init(code: code, serverTime: now))
			}
			return .failure(.init(code: .payloadTooLarge))
		}
		switch signed.verify(publicKey: key, method: method, target: target, body: body, now: now, skew: skew) {
		case .failure(let code):
			return .failure(.init(code: code, serverTime: code == .authClockSkew ? now : nil))
		case .success:
			break
		}
		guard replayCache.insert(deviceID: signed.deviceID, nonce: signed.nonce, now: now) else {
			return .failure(.init(code: .authReplay))
		}
		return .success(VerifiedRequest(deviceID: signed.deviceID, nonce: signed.nonce, timestamp: ts))
	}
}

extension SignedHeaders {
	/// Step 3 alone.
	func verifyClock(now: Int64, skew: Int64) -> Result<Void, ErrorCode> {
		guard let ts = LinkCrypto.parseTimestamp(timestamp) else { return .failure(.authClockSkew) }
		let (delta, overflow) = now.subtractingReportingOverflow(ts)
		return overflow || delta.magnitude > skew.magnitude ? .failure(.authClockSkew) : .success(())
	}
}

/// The other signatures a server checks (pairing §3.3, approvals §7.2).
public enum LinkSignatures {
	/// Both pairing proofs: the link key over `WL1-PAIR-PROOF…` (which commits to the
	/// approve key) and the approve key over `WL1-PAIR-APPROVE…`. Also refuses the
	/// same key used for both jobs.
	public static func verifyPairingProofs(
		code: String, daemonFP: String, linkKey: LinkPublicKey, approveKey: LinkPublicKey, proof: Data,
		approveProof: Data
	) -> Bool {
		guard linkKey != approveKey else { return false }
		let proofMessage = LinkCrypto.pairProofMessage(code: code, daemonFP: daemonFP, approveX963: approveKey.x963)
		let approveMessage = LinkCrypto.pairApproveMessage(code: code, daemonFP: daemonFP)
		return linkKey.isValidSignature(proof, for: proofMessage)
			&& approveKey.isValidSignature(approveProof, for: approveMessage)
	}

	/// The `X-WL-Server-Signature` value for a pairing response body.
	public static func signPairResponse(_ body: Data, daemonKey: LinkSigningKey) throws -> String {
		try daemonKey.sign(LinkCrypto.pairResponseMessage(body: body)).base64EncodedString()
	}

	/// An approval: the approve key over `WL1-APPROVE\n` + the exact canonical bytes.
	public static func verifyApproval(canonical: Data, signature: Data, approveKey: LinkPublicKey) -> Bool {
		approveKey.isValidSignature(signature, for: LinkCrypto.approvalMessage(canonical: canonical))
	}

	/// A denial: the approve key over `WL1-DENY\n` + the exact canonical bytes. Never the
	/// approve message: a captured denial must not read as an approval or the reverse.
	public static func verifyDenial(canonical: Data, signature: Data, approveKey: LinkPublicKey) -> Bool {
		approveKey.isValidSignature(signature, for: LinkCrypto.denialMessage(canonical: canonical))
	}

	/// The `X-WL-Server-Signature` value for a pairing commit acknowledgement body.
	public static func signPairCommitAck(_ body: Data, daemonKey: LinkSigningKey) throws -> String {
		try daemonKey.sign(LinkCrypto.pairCommitAckMessage(body: body)).base64EncodedString()
	}

	/// Whether a pairing reveal matches the commitment the daemon holds (constant time).
	public static func revealMatches(
		commitment: String, code: String, daemonFP: String, linkKey: LinkPublicKey, approveKey: LinkPublicKey,
		nonce: Data
	) -> Bool {
		guard nonce.count == 32 else { return false }
		let expected = LinkCrypto.pairCommitment(
			code: code, daemonFP: daemonFP, linkX963: linkKey.x963, approveX963: approveKey.x963, nonce: nonce)
		let a = Array(expected.utf8), b = Array(commitment.lowercased().utf8)
		guard a.count == b.count else { return false }
		var diff: UInt8 = 0
		for (x, y) in zip(a, b) { diff |= x ^ y }
		return diff == 0
	}
}
