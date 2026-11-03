import Foundation

/// The four WL1 auth header values of §4.1. Rust: `whispera_proto::sign::SignedHeaders`.
public struct SignedHeaders: Equatable, Sendable {
	public static let deviceHeader = "X-WL-Device"
	public static let timestampHeader = "X-WL-Timestamp"
	public static let nonceHeader = "X-WL-Nonce"
	public static let signatureHeader = "X-WL-Signature"
	/// Pairing response signature header (§3.3).
	public static let serverSignatureHeader = "X-WL-Server-Signature"

	public var deviceID: String
	public var timestamp: String
	public var nonce: String
	/// Standard base64 of the DER signature.
	public var signature: String

	public init(deviceID: String, timestamp: String, nonce: String, signature: String) {
		self.deviceID = deviceID
		self.timestamp = timestamp
		self.nonce = nonce
		self.signature = signature
	}

	/// Signs `method target body` as `deviceID` at `timestamp` (Unix seconds).
	public static func sign(
		key: LinkSigningKey, deviceID: String, method: String, target: String, body: Data,
		timestamp: Int64, nonce: String = LinkCrypto.makeNonce()
	) throws -> SignedHeaders {
		let ts = String(timestamp)
		let message = LinkCrypto.stringToSign(
			method: method, requestTarget: target, body: body, timestamp: ts, nonce: nonce, deviceID: deviceID)
		let signature = try key.sign(Data(message.utf8))
		return SignedHeaders(deviceID: deviceID, timestamp: ts, nonce: nonce, signature: signature.base64EncodedString())
	}

	/// Reads the four headers from a request; nil if any is missing.
	public init?(headers: [String: String]) {
		// HTTP header names are case-insensitive; normalise once.
		var lower: [String: String] = [:]
		for (name, value) in headers { lower[name.lowercased()] = value }
		guard let device = lower[Self.deviceHeader.lowercased()],
		      let timestamp = lower[Self.timestampHeader.lowercased()],
		      let nonce = lower[Self.nonceHeader.lowercased()],
		      let signature = lower[Self.signatureHeader.lowercased()]
		else { return nil }
		self.init(deviceID: device, timestamp: timestamp, nonce: nonce, signature: signature)
	}

	/// `(name, value)` pairs, in the order of §4.1.
	public var headerPairs: [(String, String)] {
		[
			(Self.deviceHeader, deviceID),
			(Self.timestampHeader, timestamp),
			(Self.nonceHeader, nonce),
			(Self.signatureHeader, signature),
		]
	}

	public func apply(to request: inout URLRequest) {
		for (name, value) in headerPairs { request.setValue(value, forHTTPHeaderField: name) }
	}

	/// §4.3 steps 3 and 5: clock skew, then the signature. Device lookup, revocation,
	/// body limits and the replay cache are the caller's job — `WhisperaLinkServer`'s
	/// `RequestVerifier` does all of them. Rust: `sign::verify_request`.
	///
	/// An unparsable timestamp is reported as `.authClockSkew`, as in Rust.
	public func verify(
		publicKey: LinkPublicKey, method: String, target: String, body: Data, now: Int64,
		skew: Int64 = Int64(LinkCrypto.defaultClockSkew)
	) -> Result<Void, ErrorCode> {
		guard let ts = LinkCrypto.parseTimestamp(timestamp) else { return .failure(.authClockSkew) }
		// An overflowing difference (Int64.min against Int64.max) is as skewed as it gets.
		let (delta, overflow) = now.subtractingReportingOverflow(ts)
		if overflow || delta.magnitude > skew.magnitude { return .failure(.authClockSkew) }
		let message = LinkCrypto.stringToSign(
			method: method, requestTarget: target, body: body, timestamp: timestamp, nonce: nonce, deviceID: deviceID)
		guard LinkCrypto.verify(x963: publicKey.x963, message: Data(message.utf8), signatureBase64: signature) else {
			return .failure(.authBadSignature)
		}
		return .success(())
	}
}
