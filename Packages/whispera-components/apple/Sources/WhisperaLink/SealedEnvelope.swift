import CryptoKit
import Foundation

/// Why an envelope was refused. Every case means "drop it": none is retryable.
public enum EnvelopeError: Error, Equatable, Sendable {
	/// Truncated, a bad length, trailing bytes, or not base64.
	case malformed(String)
	case unsupportedVersion(UInt8)
	/// Any ciphersuite other than P-256 / HKDF-SHA256 / AES-256-GCM.
	case unsupportedCiphersuite(kem: UInt16, kdf: UInt16, aead: UInt16)
	/// Addressed to another device: the relay misrouted it, or someone replayed it here.
	case wrongRecipient
	/// The sender's link-key signature does not verify.
	case badSignature
	/// `created_at` is outside the accepted window.
	case stale
	/// HPKE refused it: wrong agreement key, or the bytes were altered.
	case openFailed
	case invalidDeviceID(String)
}

/// The end-to-end envelope relay messages travel in: HPKE (RFC 9180) to the
/// recipient device's agreement key, signed by the sender device's link key.
///
/// The relay stores and forwards `serialized` (as standard base64 in the
/// `ciphertext` field of `RelaySendRequest` / `RelayMessage`) and learns nothing
/// but the two device ids, the time, and the length.
///
/// Wire format `WLE1`, all integers big-endian:
///
/// ```
/// magic        4   "WLE1"
/// version      1   0x01
/// kem_id       2   0x0010  DHKEM(P-256, HKDF-SHA256)
/// kdf_id       2   0x0001  HKDF-SHA256
/// aead_id      2   0x0002  AES-256-GCM
/// sender_len   1   1...255
/// sender       n   sender device id, ASCII (dev_…)
/// recip_len    1   1...255
/// recipient    n   recipient device id, ASCII
/// created_at   8   i64 Unix seconds
/// message_id  16   random
/// enc         65   HPKE encapsulated key (X9.63 P-256 point)
/// ---------------  ^ header: the AEAD's associated data
/// ct_len       4   u32
/// ct           n   HPKE ciphertext (plaintext + 16-byte GCM tag)
/// ---------------  ^ signed part: "WL1-SEAL\n" || header || ct_len || ct
/// sig_len      2   u16
/// sig          n   ECDSA P-256 / SHA-256, ASN.1 DER, by the sender's link key
/// ```
///
/// HPKE runs in base mode with `info = "whispera-link relay v1"` and one seal per
/// envelope (sequence number 0). Sender authenticity comes from the signature, not
/// HPKE auth mode, because the link key is already the registered device identity —
/// and a Secure Enclave key can sign without being exported.
public struct SealedEnvelope: Equatable, Sendable {
	public static let magic = Data("WLE1".utf8)
	public static let version: UInt8 = 1
	public static let kemID: UInt16 = 0x0010
	public static let kdfID: UInt16 = 0x0001
	public static let aeadID: UInt16 = 0x0002
	public static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
	public static let info = Data("whispera-link relay v1".utf8)
	public static let signatureContext = Data("WL1-SEAL\n".utf8)
	public static let messageIDLength = 16
	/// Accepted age of an envelope, both directions, unless the caller says otherwise.
	/// Matches the relay's longest mailbox TTL so nothing it delivers is refused as stale.
	public static let defaultMaxAge: Int64 = 7 * 24 * 3600
	/// A clock that runs ahead of ours by up to this much is tolerated.
	public static let defaultFutureSkew: Int64 = 300

	public let senderID: String
	public let recipientID: String
	public let createdAt: Int64
	public let messageID: Data
	public let encapsulatedKey: Data
	public let ciphertext: Data
	public let signature: Data

	// MARK: Sealing

	/// Seals `plaintext` to `recipientKey` and signs it as `senderID`.
	public static func seal(
		_ plaintext: Data,
		from senderID: String,
		signingKey: LinkSigningKey,
		to recipientID: String,
		recipientKey: LinkPublicKey,
		now: Int64,
		messageID: Data = LinkCrypto.randomBytes(16)
	) throws -> SealedEnvelope {
		try checkID(senderID)
		try checkID(recipientID)
		guard messageID.count == messageIDLength else { throw EnvelopeError.malformed("message_id") }
		var sender = try HPKE.Sender(recipientKey: recipientKey.agreementKey, ciphersuite: ciphersuite, info: info)
		let enc = sender.encapsulatedKey
		let header = header(sender: senderID, recipient: recipientID, createdAt: now, messageID: messageID, enc: enc)
		let ciphertext = try sender.seal(plaintext, authenticating: header)
		guard ciphertext.count <= Int(UInt32.max) else { throw EnvelopeError.malformed("too large") }
		let signature = try signingKey.sign(signedBytes(header: header, ciphertext: ciphertext))
		return SealedEnvelope(
			senderID: senderID, recipientID: recipientID, createdAt: now, messageID: messageID, encapsulatedKey: enc,
			ciphertext: ciphertext, signature: signature)
	}

	public init(
		senderID: String, recipientID: String, createdAt: Int64, messageID: Data, encapsulatedKey: Data, ciphertext: Data,
		signature: Data
	) {
		self.senderID = senderID
		self.recipientID = recipientID
		self.createdAt = createdAt
		self.messageID = messageID
		self.encapsulatedKey = encapsulatedKey
		self.ciphertext = ciphertext
		self.signature = signature
	}

	// MARK: Encoding

	public var header: Data {
		Self.header(sender: senderID, recipient: recipientID, createdAt: createdAt, messageID: messageID, enc: encapsulatedKey)
	}

	/// The bytes the sender's link key signs, `"WL1-SEAL\n"` prefix included.
	public var signedBytes: Data { Self.signedBytes(header: header, ciphertext: ciphertext) }

	public var serialized: Data {
		var out = Self.signedBody(header: header, ciphertext: ciphertext)
		out.appendBE(UInt16(signature.count))
		out.append(signature)
		return out
	}

	/// Standard base64 — what goes in the relay's `ciphertext` field.
	public var base64: String { serialized.base64EncodedString() }

	public init(base64: String) throws {
		guard let data = Data(base64Encoded: base64) else { throw EnvelopeError.malformed("base64") }
		try self.init(serialized: data)
	}

	public init(serialized data: Data) throws {
		var reader = ByteReader(Data(data))
		guard try reader.take(4) == Self.magic else { throw EnvelopeError.malformed("magic") }
		let version = try reader.byte()
		guard version == Self.version else { throw EnvelopeError.unsupportedVersion(version) }
		let kem = try reader.u16(), kdf = try reader.u16(), aead = try reader.u16()
		guard kem == Self.kemID, kdf == Self.kdfID, aead == Self.aeadID else {
			throw EnvelopeError.unsupportedCiphersuite(kem: kem, kdf: kdf, aead: aead)
		}
		let sender = try reader.shortString()
		let recipient = try reader.shortString()
		let createdAt = Int64(bitPattern: try reader.u64())
		let messageID = try reader.take(Self.messageIDLength)
		let enc = try reader.take(LinkCrypto.x963Length)
		guard LinkCrypto.isValidX963(enc) else { throw EnvelopeError.malformed("enc") }
		let ctLength = Int(try reader.u32())
		let ciphertext = try reader.take(ctLength)
		let sigLength = Int(try reader.u16())
		let signature = try reader.take(sigLength)
		guard reader.isAtEnd else { throw EnvelopeError.malformed("trailing bytes") }
		try Self.checkID(sender)
		try Self.checkID(recipient)
		self.init(
			senderID: sender, recipientID: recipient, createdAt: createdAt, messageID: messageID, encapsulatedKey: enc,
			ciphertext: ciphertext, signature: signature)
	}

	// MARK: Opening

	/// Checks the signature against the sender's registered link key.
	public func isSignatureValid(senderKey: LinkPublicKey) -> Bool {
		LinkCrypto.verify(x963: senderKey.x963, message: signedBytes, derSignature: signature)
	}

	/// The recipient's side, in order: addressed to me, signed by who it says, fresh,
	/// then decrypted. Deduplicating `messageID` is the caller's job (the relay's
	/// sequence numbers already give at-most-once delivery per mailbox).
	public func open(
		as recipientID: String,
		agreementKey: LinkAgreementKey,
		senderKey: LinkPublicKey,
		now: Int64,
		maxAge: Int64 = SealedEnvelope.defaultMaxAge,
		futureSkew: Int64 = SealedEnvelope.defaultFutureSkew
	) throws -> Data {
		guard self.recipientID == recipientID else { throw EnvelopeError.wrongRecipient }
		guard isSignatureValid(senderKey: senderKey) else { throw EnvelopeError.badSignature }
		let (age, overflow) = now.subtractingReportingOverflow(createdAt)
		guard !overflow, age <= maxAge, age >= -futureSkew else { throw EnvelopeError.stale }
		do {
			var recipient = try agreementKey.hpkeRecipient(
				ciphersuite: Self.ciphersuite, info: Self.info, encapsulatedKey: encapsulatedKey)
			return try recipient.open(ciphertext, authenticating: header)
		} catch {
			throw EnvelopeError.openFailed
		}
	}

	// MARK: Internals

	static func header(sender: String, recipient: String, createdAt: Int64, messageID: Data, enc: Data) -> Data {
		var out = Data()
		out.append(magic)
		out.append(version)
		out.appendBE(kemID)
		out.appendBE(kdfID)
		out.appendBE(aeadID)
		out.append(UInt8(sender.utf8.count))
		out.append(contentsOf: sender.utf8)
		out.append(UInt8(recipient.utf8.count))
		out.append(contentsOf: recipient.utf8)
		out.appendBE(UInt64(bitPattern: createdAt))
		out.append(messageID)
		out.append(enc)
		return out
	}

	static func signedBody(header: Data, ciphertext: Data) -> Data {
		var out = header
		out.appendBE(UInt32(ciphertext.count))
		out.append(ciphertext)
		return out
	}

	static func signedBytes(header: Data, ciphertext: Data) -> Data {
		signatureContext + signedBody(header: header, ciphertext: ciphertext)
	}

	/// 1–255 bytes of printable ASCII. Not the full `dev_…` pattern: the envelope
	/// should not need a new version the day the id format grows.
	static func checkID(_ id: String) throws {
		let bytes = Array(id.utf8)
		guard (1...255).contains(bytes.count), bytes.allSatisfy({ (0x21...0x7e).contains($0) }) else {
			throw EnvelopeError.invalidDeviceID(id)
		}
	}
}

// MARK: Byte helpers

extension Data {
	mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
		var big = value.bigEndian
		Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
	}
}

struct ByteReader {
	private let data: Data
	private var offset: Int

	init(_ data: Data) {
		self.data = data
		offset = data.startIndex
	}

	var isAtEnd: Bool { offset == data.endIndex }

	mutating func take(_ count: Int) throws -> Data {
		guard count >= 0, data.endIndex - offset >= count else { throw EnvelopeError.malformed("truncated") }
		defer { offset += count }
		return Data(data[offset..<offset + count])
	}

	mutating func byte() throws -> UInt8 { try take(1)[0] }

	mutating func u16() throws -> UInt16 { try integer() }
	mutating func u32() throws -> UInt32 { try integer() }
	mutating func u64() throws -> UInt64 { try integer() }

	private mutating func integer<T: FixedWidthInteger>() throws -> T {
		try take(MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T($1) }
	}

	mutating func shortString() throws -> String {
		let count = Int(try byte())
		guard let value = String(data: try take(count), encoding: .ascii) else { throw EnvelopeError.malformed("id") }
		return value
	}
}
