import Foundation

/// The Mach service between Whispera and its login-item helper. The helper is registered with
/// `SMAppService.loginItem`, and launchd publishes a login item's Mach service under its bundle
/// identifier, so this name is also the helper's bundle id.
public enum LinkHelperXPC {
	public static let machServiceName = "com.macwhisper.app.LinkHelper"
	public static let helperBundleIdentifier = machServiceName
	public static let appBundleIdentifier = "com.macwhisper.app"
	public static let teamIdentifier = "NK28QT38A3"

	/// Who may connect: the Developer ID-signed Whispera app and nothing else.
	public static let clientRequirement =
		"identifier \"\(appBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
	/// Who the app accepts as the helper.
	public static let helperRequirement =
		"identifier \"\(helperBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

	/// `HelperStatus` JSON, the same object the admin socket's `status` op answers.
	public static func decodeStatus(_ data: Data) -> HelperStatus? {
		try? JSONDecoder().decode(HelperStatus.self, from: data)
	}
}

/// Calls the app makes on the helper. Replies carry JSON so the protocol never has to change
/// shape when a field is added.
@objc public protocol LinkHelperXPCProtocol {
	/// `HelperStatus` as JSON.
	func status(reply: @escaping (Data) -> Void)
	/// `{"approvals":[…]}` — pending approvals for the Mac approval card (step 8).
	func pendingApprovals(reply: @escaping (Data) -> Void)

	// Account pairing (step 11). Requests and replies are JSON objects; a failure answers
	// `{"ok":false,"error":{"code","message"}}`.

	/// `{"bearer","backend_url"}` → registers this Mac on the account (once) and starts syncing.
	/// The bearer is used for registration only and never stored by the helper.
	func setAccount(_ request: Data, reply: @escaping (Data) -> Void)
	/// Leaves the account on this Mac (unpairs the account's iPhones here).
	func clearAccount(reply: @escaping (Data) -> Void)
	/// `{"status","device_id","base_url","last_sync_at","phones",…}`.
	func accountStatus(reply: @escaping (Data) -> Void)
	/// `{"devices":[{"device_id","name","fingerprint","approve_fp","safety_number","key_changed",…}]}`
	/// — iPhones waiting for the owner's confirmation. Until then they get nothing but
	/// `devices/me`.
	func pendingApproveConfirmations(reply: @escaping (Data) -> Void)
	/// The owner compared `safetyNumber` with the iPhone and confirmed `deviceID` (Touch ID in
	/// the app). The helper recomputes the number from the device's current keys and answers
	/// `keys_changed` when they no longer match what the owner saw.
	func confirmApprove(_ deviceID: String, safetyNumber: String, reply: @escaping (Data) -> Void)
}

/// One entry of `pendingApproveConfirmations`.
public struct PendingApproveConfirmation: Codable, Sendable, Equatable, Identifiable {
	public var deviceID: String
	public var name: String
	/// `xxxx-xxxx-xxxx-xxxx` of the approve key.
	public var fingerprint: String
	public var approveFP: String
	public var createdAt: Int?
	/// `1234 5678 9012`: what the owner compares with the iPhone's screen before confirming.
	public var safetyNumber: String?
	/// A device this Mac knew whose keys changed (a reinstall, or keys substituted).
	public var keyChanged: Bool

	public var id: String { deviceID }

	enum CodingKeys: String, CodingKey {
		case name, fingerprint
		case deviceID = "device_id"
		case approveFP = "approve_fp"
		case createdAt = "created_at"
		case safetyNumber = "safety_number"
		case keyChanged = "key_changed"
	}

	public init(
		deviceID: String, name: String, fingerprint: String, approveFP: String, createdAt: Int? = nil,
		safetyNumber: String? = nil, keyChanged: Bool = false
	) {
		self.deviceID = deviceID
		self.name = name
		self.fingerprint = fingerprint
		self.approveFP = approveFP
		self.createdAt = createdAt
		self.safetyNumber = safetyNumber
		self.keyChanged = keyChanged
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		deviceID = try container.decode(String.self, forKey: .deviceID)
		name = try container.decode(String.self, forKey: .name)
		fingerprint = try container.decode(String.self, forKey: .fingerprint)
		approveFP = try container.decode(String.self, forKey: .approveFP)
		createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
		safetyNumber = try container.decodeIfPresent(String.self, forKey: .safetyNumber)
		keyChanged = try container.decodeIfPresent(Bool.self, forKey: .keyChanged) ?? false
	}

	/// Decodes a `pendingApproveConfirmations` reply.
	public static func decodeList(_ data: Data) -> [PendingApproveConfirmation]? {
		struct List: Decodable { var devices: [PendingApproveConfirmation] }
		return try? JSONDecoder().decode(List.self, from: data).devices
	}
}

/// What `setAccount`, `clearAccount` and `accountStatus` answer.
public struct HelperAccountStatus: Codable, Sendable, Equatable {
	public var ok: Bool
	/// `registered`, `signed_out` or `revoked`.
	public var status: String?
	public var deviceID: String?
	public var baseURL: String?
	public var lastSyncAt: Int?
	public var lastError: String?
	public var phones: [String]?
	public var pendingConfirmations: Int?
	/// Account iPhones whose keys changed and wait for the owner's confirmation again.
	public var keyChanged: [String]?
	/// Per account iPhone: its approval push text and whether it made the latest request.
	public var phoneDetails: [PhoneDetail]?
	public var error: ErrorBody?

	public struct ErrorBody: Codable, Sendable, Equatable {
		public var code: String
		public var message: String?
	}

	public struct PhoneDetail: Codable, Sendable, Equatable {
		public var deviceID: String
		/// `named` or `generic`.
		public var pushText: String
		/// The device that signed the helper's latest request (pushed first for approvals).
		public var lastUsed: Bool

		enum CodingKeys: String, CodingKey {
			case deviceID = "device_id"
			case pushText = "push_text"
			case lastUsed = "last_used"
		}

		public init(deviceID: String, pushText: String, lastUsed: Bool) {
			self.deviceID = deviceID
			self.pushText = pushText
			self.lastUsed = lastUsed
		}
	}

	enum CodingKeys: String, CodingKey {
		case ok, status, phones, error
		case deviceID = "device_id"
		case baseURL = "base_url"
		case lastSyncAt = "last_sync_at"
		case lastError = "last_error"
		case pendingConfirmations = "pending_confirmations"
		case keyChanged = "key_changed"
		case phoneDetails = "phone_details"
	}

	public init(
		ok: Bool, status: String? = nil, deviceID: String? = nil, baseURL: String? = nil, lastSyncAt: Int? = nil,
		lastError: String? = nil, phones: [String]? = nil, pendingConfirmations: Int? = nil,
		phoneDetails: [PhoneDetail]? = nil, error: ErrorBody? = nil
	) {
		self.ok = ok
		self.status = status
		self.deviceID = deviceID
		self.baseURL = baseURL
		self.lastSyncAt = lastSyncAt
		self.lastError = lastError
		self.phones = phones
		self.pendingConfirmations = pendingConfirmations
		self.phoneDetails = phoneDetails
		self.error = error
	}

	public static func decode(_ data: Data) -> HelperAccountStatus? {
		try? JSONDecoder().decode(HelperAccountStatus.self, from: data)
	}

	public func phoneDetail(_ deviceID: String) -> PhoneDetail? {
		phoneDetails?.first { $0.deviceID == deviceID }
	}
}

public struct HelperStatus: Codable, Sendable, Equatable {
	public var ok: Bool
	public var version: String
	public var `protocol`: Int
	public var pid: Int32
	public var port: Int
	public var publicURL: String?
	public var daemonFP: String
	public var herdr: String
	public var broker: String
	public var apns: String
	public var stt: String
	public var sttMode: String?
	public var sttModels: [String]?
	public var devices: Int
	public var pendingApprovals: Int

	enum CodingKeys: String, CodingKey {
		case ok, version, `protocol`, pid, port, herdr, broker, apns, stt, devices
		case publicURL = "public_url"
		case daemonFP = "daemon_fp"
		case sttMode = "stt_mode"
		case sttModels = "stt_models"
		case pendingApprovals = "pending_approvals"
	}

	public init(
		ok: Bool, version: String, protocol: Int, pid: Int32, port: Int, publicURL: String?, daemonFP: String,
		herdr: String,
		broker: String, apns: String, stt: String, sttMode: String?, sttModels: [String]?, devices: Int,
		pendingApprovals: Int
	) {
		self.ok = ok
		self.version = version
		self.protocol = `protocol`
		self.pid = pid
		self.port = port
		self.publicURL = publicURL
		self.daemonFP = daemonFP
		self.herdr = herdr
		self.broker = broker
		self.apns = apns
		self.stt = stt
		self.sttMode = sttMode
		self.sttModels = sttModels
		self.devices = devices
		self.pendingApprovals = pendingApprovals
	}
}
