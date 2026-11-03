import CryptoKit
import Foundation

/// Errors from parsing protocol values. Mirrors Rust's `ProtoError` case for case.
public enum LinkKeyError: Error, Equatable, Sendable {
	/// `ProtoError::Base64`
	case base64
	/// `ProtoError::KeyLength` — not 65 bytes, or not the `0x04` uncompressed form.
	case keyLength
	/// `ProtoError::InvalidPoint`
	case invalidPoint
	/// `ProtoError::SpkiPrefix`
	case spkiPrefix
	/// `ProtoError::PrivateKey`
	case privateKey
}

/// A P-256 public key in the encodings of PROTOCOL §2.1: X9.63 (65 bytes, the wire
/// form), SPKI DER (91 bytes, what is hashed), SPKI PEM, and the fingerprint.
///
/// The same type serves signing keys (link, approve, daemon) and key-agreement keys
/// (the relay envelope's recipient key): the encodings are identical, only the
/// CryptoKit view differs. Rust: `whispera_proto::keys::PublicKey`.
public struct LinkPublicKey: Hashable, Sendable {
	/// X9.63 uncompressed point, `0x04 || X || Y`.
	public let x963: Data

	/// 65 bytes starting `0x04`, and on the curve.
	public init(x963: Data) throws {
		guard x963.count == LinkCrypto.x963Length, x963.first == 0x04 else { throw LinkKeyError.keyLength }
		guard (try? P256.Signing.PublicKey(x963Representation: x963)) != nil else { throw LinkKeyError.invalidPoint }
		self.x963 = Data(x963)
	}

	/// Standard base64 (padded) of the X9.63 bytes — the form every JSON body carries.
	public init(x963Base64: String) throws {
		guard let bytes = Data(base64Encoded: x963Base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			throw LinkKeyError.base64
		}
		try self.init(x963: bytes)
	}

	/// A 91-byte SPKI DER with the fixed P-256 prefix.
	public init(spkiDER der: Data) throws {
		guard der.count == LinkCrypto.spkiPrefix.count + LinkCrypto.x963Length,
		      der.prefix(LinkCrypto.spkiPrefix.count) == LinkCrypto.spkiPrefix
		else { throw LinkKeyError.spkiPrefix }
		try self.init(x963: der.suffix(LinkCrypto.x963Length))
	}

	public init(_ key: P256.Signing.PublicKey) {
		x963 = key.x963Representation
	}

	public init(_ key: P256.KeyAgreement.PublicKey) {
		x963 = key.x963Representation
	}

	public var x963Base64: String { x963.base64EncodedString() }

	/// SPKI DER: fixed prefix + 65 X9.63 bytes (91 bytes).
	public var spkiDER: Data { LinkCrypto.spki(x963: x963) }

	/// PEM `PUBLIC KEY`, base64 wrapped at 64 columns, trailing newline.
	public var spkiPEM: String {
		let b64 = spkiDER.base64EncodedString()
		var out = "-----BEGIN PUBLIC KEY-----\n"
		var index = b64.startIndex
		while index < b64.endIndex {
			let end = b64.index(index, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
			out += b64[index..<end] + "\n"
			index = end
		}
		return out + "-----END PUBLIC KEY-----\n"
	}

	/// Lowercase hex SHA-256 of the SPKI DER (64 chars).
	public var fingerprint: String { LinkCrypto.fingerprint(x963: x963) }

	/// `xxxx-xxxx-xxxx-xxxx`, the first 16 hex chars of the fingerprint.
	public var displayFingerprint: String { LinkCrypto.displayFingerprint(fingerprint) }

	/// The ECDSA view. Cannot fail: the initialisers already checked the point.
	public var signingKey: P256.Signing.PublicKey {
		// swiftlint:disable:next force_try
		try! P256.Signing.PublicKey(x963Representation: x963)
	}

	/// The ECDH / HPKE view of the same point.
	public var agreementKey: P256.KeyAgreement.PublicKey {
		// swiftlint:disable:next force_try
		try! P256.KeyAgreement.PublicKey(x963Representation: x963)
	}

	/// `verify_der_b64` against this key.
	public func isValidSignature(_ derSignature: Data, for message: Data) -> Bool {
		LinkCrypto.verify(x963: x963, message: message, derSignature: derSignature)
	}
}
