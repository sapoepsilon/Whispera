import CryptoKit
import Foundation

/// The pure protocol functions of whispera-link v1: hashes, the WL1 string to sign,
/// the other signed messages, signature checks, and the id/nonce formats.
///
/// Every function here has a twin of the same meaning in the Rust `whispera-proto`
/// crate (`sign.rs`, `keys.rs`), and both are held to `docs/vectors/v1.json`:
///
/// | Swift | Rust |
/// | --- | --- |
/// | `stringToSign(method:requestTarget:body:timestamp:nonce:deviceID:)` | `sign::string_to_sign` |
/// | `pairProofMessage` / `pairApproveMessage` / `pairResponseMessage` | `sign::pair_*_message` |
/// | `approvalMessage(canonical:)` | `sign::approval_message` |
/// | `verify(x963:message:derSignature:)` | `sign::verify_der_b64` |
/// | `isValidDeviceID` / `isValidNonce` | `sign::is_valid_device_id` / `is_valid_nonce` |
/// | `newDeviceID()` / `makeNonce()` | `sign::new_device_id` / `new_nonce` |
public enum LinkCrypto {
	/// Fixed 26-byte SPKI DER prefix for a P-256 named-curve uncompressed public key.
	public static let spkiPrefix = Data([
		0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
		0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
	])

	/// Length of an X9.63 uncompressed P-256 point.
	public static let x963Length = 65

	/// SHA-256 of the empty string, the body hash of every GET.
	public static let emptyBodySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	/// Default allowed clock skew in seconds (§4.3), `DEFAULT_CLOCK_SKEW_S` in Rust.
	public static let defaultClockSkew = 60

	// MARK: Hashes and encodings

	/// Lowercase hex SHA-256 (`body_sha256_hex`).
	public static func sha256Hex(_ data: Data) -> String {
		hex(Data(SHA256.hash(data: data)))
	}

	public static func hex(_ data: Data) -> String {
		data.map { String(format: "%02x", $0) }.joined()
	}

	/// Parses lowercase or uppercase hex; nil on odd length or a non-hex character.
	public static func data(hex: String) -> Data? {
		let chars = Array(hex.utf8)
		guard chars.count % 2 == 0 else { return nil }
		var out = Data(capacity: chars.count / 2)
		var index = 0
		while index < chars.count {
			guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
			out.append(high << 4 | low)
			index += 2
		}
		return out
	}

	private static func nibble(_ c: UInt8) -> UInt8? {
		switch c {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
		case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
		default: return nil
		}
	}

	public static func spki(x963: Data) -> Data {
		spkiPrefix + x963
	}

	/// Lowercase hex SHA-256 of the SPKI DER (64 chars).
	public static func fingerprint(x963: Data) -> String {
		sha256Hex(spki(x963: x963))
	}

	/// First 16 hex chars of a fingerprint in groups of 4: `xxxx-xxxx-xxxx-xxxx`.
	public static func displayFingerprint(_ hex: String) -> String {
		let head = Array(hex.lowercased().prefix(16))
		return stride(from: 0, to: head.count, by: 4)
			.map { String(head[$0..<min($0 + 4, head.count)]) }
			.joined(separator: "-")
	}

	/// Shape check only: 65 bytes starting `0x04`. Use `LinkPublicKey(x963:)` to also
	/// check the point is on the curve.
	public static func isValidX963(_ data: Data) -> Bool {
		data.count == x963Length && data.first == 0x04
	}

	public static func base64URLNoPad(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	public static func randomBytes(_ count: Int) -> Data {
		var generator = SystemRandomNumberGenerator()
		return Data((0..<count).map { _ in generator.next() as UInt8 })
	}

	/// Lowercase RFC 4648 base32 without padding.
	public static func base32Lower(_ data: Data) -> String {
		let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
		var output = ""
		var buffer: UInt32 = 0
		var bits = 0
		for byte in data {
			buffer = (buffer << 8) | UInt32(byte)
			bits += 8
			while bits >= 5 {
				output.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1f)])
				bits -= 5
			}
		}
		if bits > 0 {
			output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1f)])
		}
		return output
	}

	// MARK: Ids and nonces

	/// 16 random bytes, base64url without padding (22 chars).
	public static func makeNonce() -> String {
		base64URLNoPad(randomBytes(16))
	}

	/// `<prefix>_` + lowercase base32 of 15 random bytes (24 chars).
	public static func newPrefixedID(_ prefix: String) -> String {
		"\(prefix)_\(base32Lower(randomBytes(15)))"
	}

	public static func newDeviceID() -> String {
		newPrefixedID("dev")
	}

	/// `^<prefix>_[a-z2-7]{24}$`
	public static func isValidPrefixedID(_ value: String, prefix: String) -> Bool {
		guard value.hasPrefix(prefix + "_") else { return false }
		let rest = value.utf8.dropFirst(prefix.utf8.count + 1)
		return rest.count == 24
			&& rest.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "2")...UInt8(ascii: "7")).contains($0) }
	}

	/// `^dev_[a-z2-7]{24}$`
	public static func isValidDeviceID(_ value: String) -> Bool {
		isValidPrefixedID(value, prefix: "dev")
	}

	/// `^[A-Za-z0-9_-]{22}$`
	public static func isValidNonce(_ value: String) -> Bool {
		value.utf8.count == 22
			&& value.utf8.allSatisfy {
				(UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
					|| (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
					|| (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
					|| $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
			}
	}

	/// Decimal Unix seconds, ASCII digits only with an optional leading `-`, at most 18
	/// digits (`parse_timestamp`). `+1`, `" 1"` and the empty string are rejected.
	public static func parseTimestamp(_ value: String) -> Int64? {
		let digits = value.hasPrefix("-") ? value.utf8.dropFirst() : value.utf8[...]
		guard !digits.isEmpty, digits.count <= 18,
		      digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
		else { return nil }
		return Int64(value)
	}

	// MARK: Signatures

	/// ECDSA P-256 / SHA-256 verification of an ASN.1 DER signature over `message`.
	///
	/// High-S signatures are accepted, as in Rust's `verify_der_b64`: CryptoKit and
	/// OpenSSL both produce them, so rejecting them would reject real clients.
	/// Never throws; any malformed input is simply `false`.
	public static func verify(x963: Data, message: Data, derSignature: Data) -> Bool {
		guard isValidX963(x963),
		      let key = try? P256.Signing.PublicKey(x963Representation: x963),
		      let signature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature)
		else { return false }
		if key.isValidSignature(signature, for: message) { return true }
		// Belt and braces: if a platform's verifier ever starts enforcing low-S, retry
		// with the normalized twin so behaviour matches the Rust side exactly.
		guard let normalized = lowS(signature) else { return false }
		return key.isValidSignature(normalized, for: message)
	}

	/// Standard-base64 convenience (`verify_der_b64`).
	public static func verify(x963: Data, message: Data, signatureBase64: String) -> Bool {
		guard let der = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			return false
		}
		return verify(x963: x963, message: message, derSignature: der)
	}

	/// The P-256 group order n, big-endian.
	static let curveOrder: [UInt8] = [
		0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
	]

	/// `n - s` for a 32-byte big-endian `s` (both < 2^256, s < n).
	static func negateScalar(_ s: [UInt8]) -> [UInt8] {
		var out = [UInt8](repeating: 0, count: 32)
		var borrow = 0
		for i in stride(from: 31, through: 0, by: -1) {
			var value = Int(curveOrder[i]) - Int(s[i]) - borrow
			if value < 0 {
				value += 256
				borrow = 1
			} else {
				borrow = 0
			}
			out[i] = UInt8(value)
		}
		return out
	}

	/// The signature with `s` replaced by `n - s`; nil if it was already low-S.
	static func lowS(_ signature: P256.Signing.ECDSASignature) -> P256.Signing.ECDSASignature? {
		let raw = [UInt8](signature.rawRepresentation)
		let r = Array(raw[0..<32])
		let s = Array(raw[32..<64])
		let halfOrder = curveOrderHalf
		guard s.lexicographicallyPrecedes(halfOrder) == false, s != halfOrder else { return nil }
		return try? P256.Signing.ECDSASignature(rawRepresentation: Data(r + negateScalar(s)))
	}

	/// floor(n / 2), big-endian.
	static let curveOrderHalf: [UInt8] = {
		var out = [UInt8](repeating: 0, count: 32)
		var carry: UInt8 = 0
		for i in 0..<32 {
			out[i] = (curveOrder[i] >> 1) | (carry << 7)
			carry = curveOrder[i] & 1
		}
		return out
	}()

	// MARK: WL1 request signing (§4.2)

	/// `WL1\nMETHOD\ntarget\nsha256hex(body)\ntimestamp\nnonce\ndevice`, no trailing newline.
	public static func stringToSign(
		method: String, requestTarget: String, body: Data, timestamp: String, nonce: String, deviceID: String
	) -> String {
		[
			"WL1",
			asciiUppercased(method),
			requestTarget,
			body.isEmpty ? emptyBodySHA256 : sha256Hex(body),
			timestamp,
			nonce,
			deviceID,
		].joined(separator: "\n")
	}

	/// ASCII-only uppercasing, like Rust's `to_ascii_uppercase`: `ß` stays `ß`.
	static func asciiUppercased(_ value: String) -> String {
		String(decoding: value.utf8.map { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) ? $0 - 32 : $0 }, as: UTF8.self)
	}

	/// The request target exactly as it goes on the wire: percent-encoded path, plus
	/// `?query` when there is one.
	public static func requestTarget(for url: URL) -> String {
		let path = url.path(percentEncoded: true)
		if let query = url.query(percentEncoded: true) {
			return (path.isEmpty ? "/" : path) + "?" + query
		}
		return path.isEmpty ? "/" : path
	}

	/// RFC 3986 unreserved characters pass, everything else is percent-encoded — so
	/// `w3:p1` becomes `w3%3Ap1`, the form the vectors sign.
	public static func encodePathSegment(_ value: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
	}

	// MARK: Other signed messages (§3.3, §7.2)

	/// `WL1-PAIR-PROOF\n<code>\n<daemon_fp>\n<sha256hex(approve x963)>`, signed by the link key.
	public static func pairProofMessage(code: String, daemonFP: String, approveX963: Data) -> Data {
		Data("WL1-PAIR-PROOF\n\(code)\n\(daemonFP)\n\(sha256Hex(approveX963))".utf8)
	}

	/// `WL1-PAIR-APPROVE\n<code>\n<daemon_fp>`, signed by the approve key.
	public static func pairApproveMessage(code: String, daemonFP: String) -> Data {
		Data("WL1-PAIR-APPROVE\n\(code)\n\(daemonFP)".utf8)
	}

	/// `WL1-PAIR-RESP\n<sha256hex(body)>`, signed by the daemon key.
	public static func pairResponseMessage(body: Data) -> Data {
		Data("WL1-PAIR-RESP\n\(sha256Hex(body))".utf8)
	}

	/// `WL1-APPROVE\n` + the broker's canonical bytes, signed by the approve key.
	public static func approvalMessage(canonical: Data) -> Data {
		Data("WL1-APPROVE\n".utf8) + canonical
	}

	/// `WL1-DENY\n` + the broker's canonical bytes, signed by the approve key. A deny is
	/// signed like an approve so only a confirmed approver can settle a request (§7.2).
	public static func denialMessage(canonical: Data) -> Data {
		Data("WL1-DENY\n".utf8) + canonical
	}

	// MARK: Pairing v2: commit, then reveal (§3.3)

	/// The phone's commitment, sent before the code ever leaves it:
	/// `sha256hex("WL1-PAIR-COMMIT\n<code>\n<daemon_fp>\n<sha256hex(link x963)>\n<sha256hex(approve x963)>\n<b64(nonce)>")`.
	/// The 32-byte nonce stays secret until the reveal, so the commitment gives an
	/// observer nothing to brute-force the code against.
	public static func pairCommitment(
		code: String, daemonFP: String, linkX963: Data, approveX963: Data, nonce: Data
	) -> String {
		let text =
			"WL1-PAIR-COMMIT\n\(code)\n\(daemonFP)\n\(sha256Hex(linkX963))\n\(sha256Hex(approveX963))\n\(nonce.base64EncodedString())"
		return sha256Hex(Data(text.utf8))
	}

	/// `WL1-PAIR-COMMIT-ACK\n<sha256hex(body)>`, signed by the daemon key: the daemon took
	/// this exact commitment, and the phone may now reveal the code to it.
	public static func pairCommitAckMessage(body: Data) -> Data {
		Data("WL1-PAIR-COMMIT-ACK\n\(sha256Hex(body))".utf8)
	}
}
