import Foundation

/// The broker's canonical request (§7.1), parsed from the exact bytes the phone will
/// sign. The phone never re-serialises it: `bytes` is signed verbatim.
public struct CanonicalApproval: Equatable, Sendable {
	public static let knownOps: Set<String> = ["save", "bws"]

	public let bytes: Data
	public let v: Int
	public let requestID: String
	public let nonce: String
	public let op: String
	public let key: String
	public let summary: String
	public let project: String
	public let token: String
	public let host: String
	public let caller: String
	public let via: String
	public let broker: String
	public let createdAt: Int
	public let expiresAt: Int

	public enum Refusal: LocalizedError, Equatable {
		case notBase64
		case malformed(String)
		case unsupportedVersion(Int)
		case unknownOp(String)
		case requestIDMismatch
		case displayMismatch(String)
		case expired
		/// A field carries a control, bidi, zero-width or line-break character: what the
		/// screen showed could differ from the logical text, so it is never signed.
		case unsafeCharacters(String)

		public var errorDescription: String? {
			switch self {
			case .notBase64: return "The request could not be decoded. Not signing."
			case .malformed(let field): return "The request is malformed (\(field)). Not signing."
			case .unsupportedVersion(let v): return "Request version \(v) is not supported. Not signing."
			case .unknownOp(let op): return "Unknown request kind \"\(op)\". This app only signs secret access. Not signing."
			case .requestIDMismatch: return "The request id does not match. Not signing."
			case .displayMismatch(let field):
				return "The Mac's summary disagrees with the signed request (\(field)). Not signing."
			case .expired: return "This request has expired."
			case .unsafeCharacters(let field):
				return "The request's \(field) has hidden or control characters. Not signing."
			}
		}
	}

	public init(canonicalB64: String) throws {
		guard let bytes = Data(base64Encoded: canonicalB64) else { throw Refusal.notBase64 }
		try self.init(bytes: bytes)
	}

	public init(bytes: Data) throws {
		guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
			throw Refusal.malformed("not a JSON object")
		}
		// JSONSerialization keeps the first of two equal keys and Python the last: refuse
		// duplicates so every parser reads the same request.
		guard let keys = Self.topLevelKeys(bytes), Set(keys).count == keys.count else {
			throw Refusal.malformed("duplicate key")
		}
		func string(_ name: String) throws -> String {
			guard let value = object[name] as? String else { throw Refusal.malformed(name) }
			guard !value.unicodeScalars.contains(where: Self.isUnsafe) else { throw Refusal.unsafeCharacters(name) }
			return value
		}
		func int(_ name: String) throws -> Int {
			guard let number = object[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
				  let value = Int(exactly: number.doubleValue)
			else { throw Refusal.malformed(name) }
			return value
		}
		self.bytes = bytes
		v = try int("v")
		guard v == 1 else { throw Refusal.unsupportedVersion(v) }
		requestID = try string("request_id")
		nonce = try string("nonce")
		op = try string("op")
		guard Self.knownOps.contains(op) else { throw Refusal.unknownOp(op) }
		key = try string("key")
		summary = try string("summary")
		project = try string("project")
		token = try string("token")
		host = try string("host")
		caller = try string("caller")
		via = try string("via")
		broker = try string("broker")
		createdAt = try int("created_at")
		expiresAt = try int("expires_at")
	}

	/// The §5.6 checks that must pass before the Approve button can sign.
	public func validate(against detail: ApprovalDetail, pathID: String, now: Int) throws {
		guard requestID == pathID, detail.request_id == pathID else { throw Refusal.requestIDMismatch }
		let pairs: [(String, String, String)] = [
			("op", op, detail.display.op),
			("summary", summary, detail.display.summary),
			("key", key, detail.display.key),
			("project", project, detail.display.project),
			("token", token, detail.display.token),
			("host", host, detail.display.host),
			("caller", caller, detail.display.caller),
			("via", via, detail.display.via),
			("broker", broker, detail.display.broker),
		]
		for (name, signed, shown) in pairs where signed != shown {
			throw Refusal.displayMismatch(name)
		}
		guard expiresAt == detail.expires_at else { throw Refusal.displayMismatch("expires_at") }
		guard now < expiresAt - 2 else { throw Refusal.expired }
	}

	public var signedMessage: Data { LinkCrypto.approvalMessage(canonical: bytes) }

	/// What a Deny signs (`WL1-DENY\n` + the same bytes).
	public var denialMessage: Data { LinkCrypto.denialMessage(canonical: bytes) }

	/// Which Bitwarden token the broker will use: a read request asking for the write token
	/// must stand out.
	public enum TokenKind: Equatable, Sendable {
		case read, write
		case other(String)
	}

	public var tokenKind: TokenKind {
		switch token.lowercased() {
		case "read": return .read
		case "write": return .write
		default: return .other(token)
		}
	}

	/// C0/C1 controls (newlines included), DEL, bidi embeddings/overrides/isolates and
	/// marks, zero-width characters, line/paragraph separators and the BOM.
	public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x00...0x1F, 0x7F...0x9F: return true
		case 0x061C, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2069, 0xFEFF: return true
		default: return false
		}
	}

	/// The keys of a flat JSON object, in order, or nil when it is not one.
	static func topLevelKeys(_ bytes: Data) -> [String]? {
		var keys: [String] = []
		var depth = 0
		var inString = false
		var escaped = false
		var current: [UInt8] = []
		var expectKey = false
		var readingKey = false
		for byte in bytes {
			if inString {
				if escaped {
					escaped = false
					if readingKey { current.append(byte) }
				} else if byte == UInt8(ascii: "\\") {
					escaped = true
					if readingKey { current.append(byte) }
				} else if byte == UInt8(ascii: "\"") {
					inString = false
					if readingKey {
						// Decode escapes, so `"k\u0065y"` and `"key"` count as the same key.
						let quoted = Data([UInt8(ascii: "\"")] + current + [UInt8(ascii: "\"")])
						guard let key = try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String
						else { return nil }
						keys.append(key)
						readingKey = false
					}
				} else if readingKey {
					current.append(byte)
				}
				continue
			}
			switch byte {
			case UInt8(ascii: "{"), UInt8(ascii: "["):
				depth += 1
				expectKey = byte == UInt8(ascii: "{") && depth == 1
			case UInt8(ascii: "}"), UInt8(ascii: "]"):
				depth -= 1
			case UInt8(ascii: ","):
				expectKey = depth == 1
			case UInt8(ascii: "\""):
				inString = true
				if expectKey {
					readingKey = true
					current = []
					expectKey = false
				}
			case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
				break
			default:
				if depth == 1, expectKey { return nil }
			}
		}
		return depth == 0 ? keys : nil
	}
}
