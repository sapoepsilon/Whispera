import CryptoKit
import Foundation

/// WLP1: the approval push text, sealed by the Mac for the phone's Notification
/// Service Extension so the backend and APNs only ever carry an opaque blob.
///
/// ```
/// shared = ECDH(P-256, phone agreement key, Mac account agreement key)   (kem_pubkey keys)
/// key    = HKDF-SHA256(ikm: shared, salt: "WLP1", info: "whispera push v1|<phone id>|<mac id>", 32 B)
/// sealed = base64( nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16) ),  AAD = "WLP1\n" + request_id
/// plain  = {"body":"…","request_id":"apr_…","title":"…"}   (sorted-keys JSON, ≤ 1 KiB)
/// ```
///
/// Both ids are account device ids. The phone derives the key once per paired Mac
/// and leaves it where its extension can read it (`PushKeyring`).
public enum PushSealing {
	public static let salt = Data("WLP1".utf8)
	public static let aadPrefix = "WLP1\n"
	public static let nonceLength = 12
	public static let tagLength = 16
	/// Longest plaintext the Mac may seal; the backend caps `sealed` at 2048 base64 chars.
	public static let maxPlaintext = 1024
	public static let maxSealedBase64 = 2048

	public enum Error: Swift.Error, Equatable, Sendable {
		/// Not base64, or shorter than nonce + tag.
		case malformed
		/// The tag did not verify: wrong key, wrong request id, or altered bytes.
		case openFailed
		/// The plaintext is over `maxPlaintext`.
		case tooLarge
		/// The plaintext's `request_id` is not the one it was opened for.
		case requestIDMismatch
		case badPayload
	}

	public static func info(phoneID: String, macID: String) -> Data {
		Data("whispera push v1|\(phoneID)|\(macID)".utf8)
	}

	public static func aad(requestID: String) -> Data {
		Data((aadPrefix + requestID).utf8)
	}

	/// The 32-byte key from an ECDH secret.
	public static func deriveKey(sharedSecret: SharedSecret, phoneID: String, macID: String) -> SymmetricKey {
		sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self, salt: salt, sharedInfo: info(phoneID: phoneID, macID: macID), outputByteCount: 32)
	}

	/// The key from this device's agreement key and the peer's — the phone passes its
	/// own key and the Mac's, the Mac its own and the phone's; both get the same key.
	public static func deriveKey(
		agreementKey: LinkAgreementKey, peerKey: LinkPublicKey, phoneID: String, macID: String
	) throws -> SymmetricKey {
		deriveKey(sharedSecret: try agreementKey.sharedSecret(with: peerKey), phoneID: phoneID, macID: macID)
	}

	/// Seals raw plaintext. `nonce` is for test vectors only; leave it nil.
	public static func seal(
		_ plaintext: Data, requestID: String, key: SymmetricKey, nonce: AES.GCM.Nonce? = nil
	) throws -> String {
		guard plaintext.count <= maxPlaintext else { throw Error.tooLarge }
		let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce ?? AES.GCM.Nonce(), authenticating: aad(requestID: requestID))
		// `combined` is nonce ‖ ciphertext ‖ tag for the default 12-byte nonce.
		guard let combined = box.combined else { throw Error.malformed }
		return combined.base64EncodedString()
	}

	public static func seal(_ payload: PushPayload, key: SymmetricKey, nonce: AES.GCM.Nonce? = nil) throws -> String {
		try seal(try payload.encoded(), requestID: payload.request_id, key: key, nonce: nonce)
	}

	/// Opens to raw plaintext.
	public static func openData(_ sealed: String, requestID: String, key: SymmetricKey) throws -> Data {
		guard sealed.count <= maxSealedBase64, let data = Data(base64Encoded: sealed),
			data.count >= nonceLength + tagLength
		else { throw Error.malformed }
		do {
			let box = try AES.GCM.SealedBox(combined: data)
			return try AES.GCM.open(box, using: key, authenticating: aad(requestID: requestID))
		} catch {
			throw Error.openFailed
		}
	}

	/// Opens and decodes, checking the payload names the same request.
	public static func open(_ sealed: String, requestID: String, key: SymmetricKey) throws -> PushPayload {
		let plaintext = try openData(sealed, requestID: requestID, key: key)
		guard let payload = try? JSONDecoder().decode(PushPayload.self, from: plaintext) else { throw Error.badPayload }
		guard payload.request_id == requestID else { throw Error.requestIDMismatch }
		return payload
	}
}

/// The plaintext of a WLP1 blob.
public struct PushPayload: Codable, Equatable, Sendable {
	public var title: String
	public var body: String
	public var request_id: String

	/// Upper bound on `title` + `body`.
	public static let maxTextLength = 180

	public init(title: String, body: String, request_id: String) {
		self.title = title
		self.body = body
		self.request_id = request_id
	}

	/// Sorted-keys JSON.
	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(self)
	}

	/// Named mode: title `"<caller or agent> wants <key>"`, body
	/// `"<summary> · <project> · on <Mac name>"` with empty parts omitted, the whole
	/// cut to `maxTextLength` characters (body first, then title, with `…`).
	public static func named(
		requester: String, key: String, summary: String, project: String, macName: String, requestID: String
	) -> PushPayload {
		let who = requester.trimmingCharacters(in: .whitespacesAndNewlines)
		let what = key.trimmingCharacters(in: .whitespacesAndNewlines)
		var title = [who.isEmpty ? "Someone" : who, "wants", what.isEmpty ? "approval" : what].joined(separator: " ")
		let mac = macName.trimmingCharacters(in: .whitespacesAndNewlines)
		let parts = [summary, project].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } + [mac.isEmpty ? "" : "on \(mac)"]
		var body = parts.filter { !$0.isEmpty }.joined(separator: " · ")
		if title.count > maxTextLength { title = String(title.prefix(maxTextLength - 1)) + "…" }
		let room = maxTextLength - title.count
		if body.count > room { body = room > 1 ? String(body.prefix(room - 1)) + "…" : "" }
		return PushPayload(title: title, body: body, request_id: requestID)
	}
}

/// The phone's WLP1 keys for its Notification Service Extension: `push-keys.json` in
/// the app group, a map of Mac account device id → standard base64 key.
public struct PushKeyring: Codable, Equatable, Sendable {
	public static let fileName = "push-keys.json"
	public static let appGroup = "group.com.chatgenie.Whispera"

	public var keys: [String: String]

	public init(keys: [String: String] = [:]) {
		self.keys = keys
	}

	public func key(for macID: String) -> SymmetricKey? {
		guard let raw = keys[macID].flatMap({ Data(base64Encoded: $0) }), raw.count == 32 else { return nil }
		return SymmetricKey(data: raw)
	}

	public mutating func set(_ key: SymmetricKey?, for macID: String) {
		keys[macID] = key?.withUnsafeBytes { Data($0).base64EncodedString() }
	}

	/// Tries every key — the extension may not know which Mac sent the push.
	public func open(_ sealed: String, requestID: String) -> (macID: String, payload: PushPayload)? {
		for macID in keys.keys.sorted() {
			guard let key = key(for: macID) else { continue }
			if let payload = try? PushSealing.open(sealed, requestID: requestID, key: key) { return (macID, payload) }
		}
		return nil
	}

	/// The app-group file URL, when the group is available to this process.
	public static func fileURL(appGroup: String = PushKeyring.appGroup) -> URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
	}

	public static func load(from url: URL) -> PushKeyring {
		guard let data = try? Data(contentsOf: url), let ring = try? JSONDecoder().decode(PushKeyring.self, from: data) else {
			return PushKeyring()
		}
		return ring
	}

	/// Atomic write, readable after first unlock (the extension runs while locked).
	public func save(to url: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}

	// A bare map on disk, `{"<mac id>":"<b64>"}`, as the contract says.
	public init(from decoder: Decoder) throws {
		keys = try decoder.singleValueContainer().decode([String: String].self)
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		try c.encode(keys)
	}
}
