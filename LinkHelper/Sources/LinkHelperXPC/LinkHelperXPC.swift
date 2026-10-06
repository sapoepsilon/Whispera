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
