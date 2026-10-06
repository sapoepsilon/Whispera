import Foundation

/// Effective configuration (PROTOCOL §1.3, §1.4): defaults, then `config.json`, then the
/// `WHISPERA_LINK_*` environment overrides. Same files and variables as the Python daemon, so
/// the helper can take over an existing install and the e2e scripts drive both unchanged.
public struct HelperConfig: Sendable {
	public var listenHost = "0.0.0.0"
	public var port = 7787
	public var publicURL = ""
	public var herdrSocket = "~/.config/herdr/herdr.sock"
	public var clockSkew = 60
	public var pairCodeTTL = 300
	public var maxJSONBytes = 65536
	public var sttUpstreamBaseURL = ""
	public var sttUpstreamAPIKeyFile = ""
	public var sttTimeout: Double = 120
	public var sttMaxUploadBytes = 26_214_400
	public var apnsTopic = "com.chatgenie.Whispera"
	public var apnsDefaultEnv = "sandbox"
	public var relayBaseURL = ""
	public var relayDeviceID = ""
	public var logDebug = false
	public var bonjour = true
	public var ssePingInterval: Double = 15
	public var testSkipApprovePrecheck = false
	public var paths: Paths

	public struct Paths: Sendable {
		public var config: String
		public var stateDir: String
		public var log: String

		public var daemonKey: String { stateDir + "/daemon_key.pem" }
		public var devices: String { stateDir + "/devices.json" }
		public var keysDir: String { stateDir + "/keys" }
		public var apnsDir: String { stateDir + "/apns" }
		public var approvalsSocket: String { stateDir + "/approvals.sock" }
		public var adminSocket: String { stateDir + "/admin.sock" }
		public var lastDevice: String { stateDir + "/last_device" }
		public var relayKey: String { stateDir + "/relay_link_key.pem" }
	}

	public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

	public init(paths: Paths) {
		self.paths = paths
	}

	/// Loads the effective config. `warn` receives one line per ignored file or value.
	public static func load(
		environment env: [String: String] = ProcessInfo.processInfo.environment,
		warn: (String) -> Void = { _ in }
	) -> HelperConfig {
		let home = homeDirectory(env)
		let configPath = expand(
			nonEmpty(env["WHISPERA_LINK_CONFIG"]) ?? "~/.config/whispera-link/config.json", home)
		let stateDir = expand(nonEmpty(env["WHISPERA_LINK_HOME"]) ?? "~/.whispera-link", home)
		let logPath = expand(nonEmpty(env["WHISPERA_LINK_LOG"]) ?? "~/Library/Logs/whispera-link.log", home)
		var cfg = HelperConfig(paths: Paths(config: configPath, stateDir: stateDir, log: logPath))

		if let data = FileManager.default.contents(atPath: configPath) {
			if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
				cfg.merge(object, warn: warn)
			} else {
				warn("ignoring config \(configPath): not a JSON object")
			}
		}

		if let port = nonEmpty(env["WHISPERA_LINK_PORT"]).flatMap(Int.init) { cfg.port = port }
		if let host = nonEmpty(env["WHISPERA_LINK_LISTEN_HOST"]) { cfg.listenHost = host }
		if let url = nonEmpty(env["WHISPERA_LINK_PUBLIC_URL"]) { cfg.publicURL = url }
		if let socket = nonEmpty(env["WHISPERA_LINK_HERDR_SOCKET"]) { cfg.herdrSocket = socket }
		if let ping = nonEmpty(env["WHISPERA_LINK_SSE_PING_S"]).flatMap(Double.init), ping > 0 {
			cfg.ssePingInterval = ping
		}
		if env["WHISPERA_LINK_BONJOUR"] == "0" { cfg.bonjour = false }
		cfg.testSkipApprovePrecheck = env["WHISPERA_LINK_TEST_SKIP_APPROVE_PRECHECK"] == "1"
		cfg.herdrSocket = expand(cfg.herdrSocket, home)
		if !cfg.sttUpstreamAPIKeyFile.isEmpty {
			cfg.sttUpstreamAPIKeyFile = expand(cfg.sttUpstreamAPIKeyFile, home)
		}
		return cfg
	}

	private mutating func merge(_ object: [String: Any], warn: (String) -> Void) {
		func int(_ key: String, _ value: Any?) -> Int? {
			guard let value else { return nil }
			if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
				return number.intValue
			}
			if let text = value as? String, let parsed = Int(text) { return parsed }
			warn("ignoring \(key): not an integer")
			return nil
		}
		func double(_ value: Any?) -> Double? {
			(value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
		}
		func string(_ value: Any?) -> String? { value as? String }

		for (key, value) in object where !key.hasPrefix("_") {
			switch key {
			case "listen_host": if let v = string(value) { listenHost = v }
			case "port": if let v = int(key, value) { port = v }
			case "public_url": if let v = string(value) { publicURL = v }
			case "herdr_socket": if let v = string(value) { herdrSocket = v }
			case "clock_skew_s": if let v = int(key, value) { clockSkew = v }
			case "pair_code_ttl_s": if let v = int(key, value) { pairCodeTTL = v }
			case "max_json_bytes": if let v = int(key, value) { maxJSONBytes = v }
			case "log_debug": if let v = value as? Bool { logDebug = v }
			case "bonjour": if let v = value as? Bool { bonjour = v }
			case "stt":
				guard let stt = value as? [String: Any] else { continue }
				if let v = string(stt["upstream_base_url"]) { sttUpstreamBaseURL = v }
				if let v = string(stt["upstream_api_key_file"]) { sttUpstreamAPIKeyFile = v }
				if let v = double(stt["timeout_s"]) { sttTimeout = v }
				if let v = int("stt.max_upload_bytes", stt["max_upload_bytes"]) { sttMaxUploadBytes = v }
			case "apns":
				guard let apns = value as? [String: Any] else { continue }
				if let v = string(apns["topic"]) { apnsTopic = v }
				if let v = string(apns["default_env"]) { apnsDefaultEnv = v }
			case "relay":
				guard let relay = value as? [String: Any] else { continue }
				if let v = string(relay["base_url"]) { relayBaseURL = v }
				if let v = string(relay["device_id"]) { relayDeviceID = v }
			default:
				continue
			}
		}
	}

	/// `public_url` from config, else `http://<hostname -s>.local:<port>`, or
	/// `http://127.0.0.1:<port>` when listening on loopback only. Returns (url, warning).
	public func effectivePublicURL(boundPort: Int) -> (String, String?) {
		var url = publicURL
		while url.hasSuffix("/") { url.removeLast() }
		if !url.isEmpty { return (url, nil) }
		if Self.loopbackHosts.contains(listenHost) { return ("http://127.0.0.1:\(boundPort)", nil) }
		let short = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "localhost"
		let derived = "http://\(short.isEmpty ? "localhost" : short).local:\(boundPort)"
		return (derived, "public_url is empty; using \(derived) in the pairing QR")
	}

	static func homeDirectory(_ env: [String: String]) -> String {
		nonEmpty(env["HOME"]) ?? NSHomeDirectory()
	}

	static func expand(_ path: String, _ home: String) -> String {
		if path == "~" { return home }
		if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
		return path
	}

	private static func nonEmpty(_ value: String?) -> String? {
		guard let value, !value.isEmpty else { return nil }
		return value
	}
}
