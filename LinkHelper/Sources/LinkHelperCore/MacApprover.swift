import Foundation
import WhisperaLink

/// The Mac's own approver (PROTOCOL §8.1): Whispera's approval card signs with a Secure Enclave
/// approve key that lives in the app, and the broker verifies it against a pin exactly like a
/// phone's. The helper keeps only the public half, in `mac_approver.json`, plus the same key as a
/// PEM for `bws-touchid approver add`.
public struct MacApprover: Sendable, Equatable {
	public var deviceID: String
	public var name: String
	public var approvePubkey: String
	public var createdAt: Int

	public init(deviceID: String, name: String, approvePubkey: String, createdAt: Int) {
		self.deviceID = deviceID
		self.name = name
		self.approvePubkey = approvePubkey
		self.createdAt = createdAt
	}

	init?(json: [String: Any]) {
		guard let id = json["device_id"] as? String, LinkCrypto.isValidDeviceID(id),
			let pubkey = json["approve_pubkey"] as? String, (try? LinkPublicKey(x963Base64: pubkey)) != nil
		else { return nil }
		deviceID = id
		name = String((json["name"] as? String ?? "").prefix(60))
		approvePubkey = pubkey
		createdAt = WireJSON.strictInt(json["created_at"]) ?? 0
	}

	var publicKey: LinkPublicKey? { try? LinkPublicKey(x963Base64: approvePubkey) }

	public var json: [String: Any] {
		let key = publicKey
		return [
			"v": 1, "device_id": deviceID, "name": name, "approve_pubkey": approvePubkey,
			"approve_fp": key?.fingerprint ?? "", "display_fp": key?.displayFingerprint ?? "",
			"created_at": createdAt,
		]
	}

	/// The record the approvals table decides with: the Mac stands in for a paired device whose
	/// approve key is the card's key. It never signs requests, so it has no link key of its own.
	/// It is never stored in, or looked up from, the device registry (`decideFromMac`).
	/// Confirmation is stated, not inherited from an init default: the owner enrolled this key
	/// from the signed Whispera app on this Mac, which is the confirmation an account iPhone
	/// still needs.
	var deviceRecord: DeviceRecord? {
		guard let key = publicKey else { return nil }
		return DeviceRecord(
			deviceID: deviceID, name: name, link: key, approve: key, sttKeySHA256: "", apns: nil, app: nil,
			now: createdAt, approveConfirmed: true, origin: .code)
	}
}

/// `mac_approver.json` (0600) and `mac_approver.pem` in the state dir.
public final class MacApproverStore: @unchecked Sendable {
	let path: String
	public let pemPath: String
	private let lock = NSLock()
	private var cached: MacApprover?
	private var loaded = false

	public init(stateDir: String) {
		path = stateDir + "/mac_approver.json"
		pemPath = stateDir + "/mac_approver.pem"
	}

	public var current: MacApprover? {
		lock.lock()
		defer { lock.unlock() }
		if !loaded {
			loaded = true
			cached = ((try? FileStore.readJSON(path)) as? [String: Any]).flatMap(MacApprover.init(json:))
		}
		return cached
	}

	/// Stores the card's public key; an empty object removes it.
	public func enroll(_ request: [String: Any], now: Int) throws -> MacApprover? {
		lock.lock()
		defer { lock.unlock() }
		if request.isEmpty {
			try? FileManager.default.removeItem(atPath: path)
			try? FileManager.default.removeItem(atPath: pemPath)
			cached = nil
			loaded = true
			return nil
		}
		var fields = request
		fields["created_at"] = now
		guard let approver = MacApprover(json: fields), let key = approver.publicKey else {
			throw APIError(400, "bad_request", "device_id or approve_pubkey is invalid")
		}
		try FileStore.writeAtomic(Data(key.spkiPEM.utf8), to: pemPath)
		try FileStore.writeJSONAtomic(approver.json, to: path)
		cached = approver
		loaded = true
		return approver
	}
}
