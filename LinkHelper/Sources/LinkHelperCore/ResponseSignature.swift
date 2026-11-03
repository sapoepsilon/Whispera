import Foundation
import WhisperaLink

/// Signs what the helper answers on a direct connection, with the daemon key the phone pinned at
/// pairing (`daemon_pubkey` / `daemon_fp`). Requests are WL1-signed by the phone; this gives the
/// answers the same integrity, so a plain-LAN peer (`allow_lan_http`) cannot rewrite a status,
/// a body or an event in flight. Wire format: docs/LINK_RESPONSE_SIGNATURES.md.
///
/// Every response gets two headers:
///
///     X-WL-Response-Timestamp: <unix seconds>
///     X-WL-Response-Signature: <standard base64 of the ASN.1 DER ECDSA P-256 / SHA-256 signature>
///
/// over `WL1-RESP\n<ts>\n<nonce>\n<METHOD>\n<target>\n<status>\n<sha256hex(body) | "stream">`.
/// An SSE stream additionally carries a `wl-sig: <seq> <ts> <sig>` field as the last line of
/// every event that has a non-comment line, over
/// `WL1-RESP-EVENT\n<ts>\n<nonce>\n<seq>\n<sha256hex(event bytes)>`.
public struct ResponseSigner: Sendable {
	public static let timestampHeader = "X-WL-Response-Timestamp"
	public static let signatureHeader = "X-WL-Response-Signature"
	/// The SSE field carrying an event's signature. Unknown fields are ignored by SSE parsers.
	public static let eventField = "wl-sig"
	static let responseTag = "WL1-RESP"
	static let eventTag = "WL1-RESP-EVENT"
	/// Stands in for the body hash in a stream's head: its body is signed event by event.
	static let streamMarker = "stream"

	let key: any LinkSigningKey
	let now: @Sendable () -> Int64

	public init(key: any LinkSigningKey, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
		self.key = key
		self.now = now
	}

	/// The request's `X-WL-Nonce` when it is a well-formed nonce, else empty: a response to an
	/// unsigned or malformed request is still signed, bound to no nonce.
	static func boundNonce(_ header: String?) -> String {
		guard let header, LinkCrypto.isValidNonce(header) else { return "" }
		return header
	}

	/// One line per field: any byte outside visible ASCII is percent-encoded, so no request field
	/// can contain the newline that separates them.
	static func field(_ value: String) -> String {
		var out = ""
		for byte in value.utf8 {
			if (0x21...0x7e).contains(byte) {
				out.unicodeScalars.append(Unicode.Scalar(byte))
			} else {
				out += String(format: "%%%02X", byte)
			}
		}
		return out
	}

	static func asciiUppercased(_ value: String) -> String {
		String(decoding: value.utf8.map { (0x61...0x7a).contains($0) ? $0 - 32 : $0 }, as: UTF8.self)
	}

	static func bodyHash(_ body: Data) -> String {
		body.isEmpty ? LinkCrypto.emptyBodySHA256 : LinkCrypto.sha256Hex(body)
	}

	/// `WL1-RESP\n<ts>\n<nonce>\n<METHOD>\n<target>\n<status>\n<body hash or "stream">`, no
	/// trailing newline.
	public static func responseMessage(
		timestamp: Int64, nonce: String, method: String, target: String, status: Int, bodyHash: String
	) -> Data {
		Data(
			[
				responseTag, String(timestamp), field(nonce), field(asciiUppercased(method)), field(target),
				String(status), bodyHash,
			].joined(separator: "\n").utf8)
	}

	/// `WL1-RESP-EVENT\n<ts>\n<nonce>\n<seq>\n<sha256hex(event bytes)>`, no trailing newline.
	public static func eventMessage(timestamp: Int64, nonce: String, seq: UInt64, event: Data) -> Data {
		Data(
			[eventTag, String(timestamp), field(nonce), String(seq), LinkCrypto.sha256Hex(event)].joined(
				separator: "\n"
			).utf8)
	}

	/// The two headers for a complete response (`body` exactly as sent), or for a stream's head
	/// when `body` is nil.
	func headers(nonce: String, method: String, target: String, status: Int, body: Data?) -> [(String, String)] {
		let ts = now()
		let message = Self.responseMessage(
			timestamp: ts, nonce: nonce, method: method, target: target, status: status,
			bodyHash: body.map(Self.bodyHash) ?? Self.streamMarker)
		guard let signature = try? key.sign(message) else { return [] }
		return [(Self.timestampHeader, String(ts)), (Self.signatureHeader, signature.base64EncodedString())]
	}

	func eventLine(nonce: String, seq: UInt64, event: Data) -> Data? {
		let ts = now()
		guard let signature = try? key.sign(Self.eventMessage(timestamp: ts, nonce: nonce, seq: seq, event: event))
		else { return nil }
		return Data("\(Self.eventField): \(seq) \(ts) \(signature.base64EncodedString())\n".utf8)
	}

	// MARK: Verifying (what a client does; the tests use it)

	public enum Failure: Error, Equatable {
		case missing
		case badSignature
		case stale
	}

	/// Checks a complete response's two headers against the request the client sent; `maxAge`
	/// bounds how old the timestamp may be (nil skips it).
	public static func verifyResponse(
		publicKey: LinkPublicKey, nonce: String, method: String, target: String, status: Int, body: Data?,
		headers: [String: String], now: Int64? = nil, maxAge: Int64? = nil
	) -> Result<Int64, Failure> {
		var lower: [String: String] = [:]
		for (name, value) in headers { lower[name.lowercased()] = value }
		guard let rawTS = lower[timestampHeader.lowercased()], let ts = LinkCrypto.parseTimestamp(rawTS),
			let rawSig = lower[signatureHeader.lowercased()], let signature = Data(base64Encoded: rawSig)
		else { return .failure(.missing) }
		let message = responseMessage(
			timestamp: ts, nonce: nonce, method: method, target: target, status: status,
			bodyHash: body.map(bodyHash) ?? streamMarker)
		guard publicKey.isValidSignature(signature, for: message) else { return .failure(.badSignature) }
		if let now, let maxAge, (now - ts).magnitude > maxAge.magnitude { return .failure(.stale) }
		return .success(ts)
	}

	/// Splits one SSE event block (its lines with their `\n`, without the blank line that ends
	/// it) into the signed bytes and its `wl-sig` field, then checks it.
	public static func verifyEvent(
		publicKey: LinkPublicKey, nonce: String, expectedSeq: UInt64, block: Data
	) -> Result<Data, Failure> {
		let prefix = Data("\n\(eventField): ".utf8)
		let start: Data.Index
		if block.starts(with: Data("\(eventField): ".utf8)) {
			start = block.startIndex
		} else if let range = block.range(of: prefix, options: .backwards) {
			start = range.lowerBound + 1
		} else {
			return .failure(.missing)
		}
		let signed = block[block.startIndex..<start]
		let line = String(decoding: block[start...], as: UTF8.self)
			.dropFirst(eventField.count + 2).trimmingCharacters(in: .newlines)
		let parts = line.split(separator: " ")
		guard parts.count == 3, let seq = UInt64(parts[0]), let ts = LinkCrypto.parseTimestamp(String(parts[1])),
			let signature = Data(base64Encoded: String(parts[2]))
		else { return .failure(.missing) }
		guard seq == expectedSeq,
			publicKey.isValidSignature(signature, for: eventMessage(timestamp: ts, nonce: nonce, seq: seq, event: Data(signed)))
		else { return .failure(.badSignature) }
		return .success(Data(signed))
	}
}

/// Adds a `wl-sig` line to each SSE event an `HTTPExchange` writes. Events are complete blocks
/// ending in a blank line; bytes after the last one wait for the next write. A block of comment
/// lines only (`: ping`) passes unsigned and takes no sequence number.
final class SSEEventSigner: @unchecked Sendable {
	private let signer: ResponseSigner
	private let nonce: String
	private let lock = NSLock()
	private var pending = Data()
	private var seq: UInt64 = 0

	init(signer: ResponseSigner, nonce: String) {
		self.signer = signer
		self.nonce = nonce
	}

	func process(_ data: Data) -> Data {
		lock.lock()
		defer { lock.unlock() }
		pending.append(data)
		let terminator = Data("\n\n".utf8)
		var out = Data()
		while let end = pending.range(of: terminator) {
			// The event's lines, each with its own `\n`.
			let block = pending[pending.startIndex..<(end.lowerBound + 1)]
			out.append(block)
			if Self.hasField(block) {
				seq += 1
				if let line = signer.eventLine(nonce: nonce, seq: seq, event: Data(block)) { out.append(line) }
			}
			out.append(UInt8(ascii: "\n"))
			pending = Data(pending[end.upperBound...])
		}
		return out
	}

	private static func hasField(_ block: Data) -> Bool {
		block.split(separator: UInt8(ascii: "\n")).contains { $0.first != UInt8(ascii: ":") }
	}
}
