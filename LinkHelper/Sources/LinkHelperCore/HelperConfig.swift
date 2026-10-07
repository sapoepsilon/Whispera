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
	/// Account pairing (step 11). Normally the app hands the bearer over XPC; these let the
	/// helper run standalone (e2e): a backend URL and a bearer to register with at start.
	public var accountBackendURL = ""
	/// Never written to disk or logged; used once to register the Mac.
	public var accountBearer = ""
	/// Long-poll wait of the account sync loop, seconds (0 = poll every second).
	public var accountPollWait = 25
	/// Overrides the base URLs a link offer advertises (comma-separated in the environment).
	public var offerBaseURLs: [String] = []
	/// The name phones show for this Mac; empty = the computer name.
	public var macName = ""
	/// Test only: lets the admin socket confirm a device's approve rights without Touch ID.
	public var testAdminConfirm = false
	/// The herdr CLI that reaches the other herdr machines (`herdr machine list`,
	/// `herdr --machine <id> …`). A bare name is looked up on PATH and ~/.local/bin; empty turns
	/// remote machines off.
	public var herdrCLI = "herdr"
	/// Seconds before the other phones are pushed while an approval is still pending.
	public var approvalFallback: Double = 20
	/// Seconds between status polls of the remote herdr machines (only while a phone listens).
	public var remotePollInterval: Double = 10
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
		/// The relay agreement key a phone seals `LinkMessage`s to (published as `kem_pubkey`).
		public var relayKEMKey: String { stateDir + "/relay_kem_key.pem" }
		/// Account registration and sync state (device id, base URL, relay cursor, offers sent).
		public var accountState: String { stateDir + "/account.json" }
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
		#if DEBUG
			// Test-only switches; a release build never reads them from the environment.
			cfg.testSkipApprovePrecheck = env["WHISPERA_LINK_TEST_SKIP_APPROVE_PRECHECK"] == "1"
			cfg.testAdminConfirm = env["WHISPERA_LINK_TEST_ADMIN_CONFIRM"] == "1"
		#endif
		if let url = nonEmpty(env["WHISPERA_LINK_RELAY_BASE_URL"]) { cfg.relayBaseURL = url }
		if let url = nonEmpty(env["WHISPERA_LINK_ACCOUNT_BACKEND_URL"]) { cfg.accountBackendURL = url }
		if let bearer = nonEmpty(env["WHISPERA_LINK_ACCOUNT_BEARER"]) { cfg.accountBearer = bearer }
		if let wait = nonEmpty(env["WHISPERA_LINK_ACCOUNT_POLL_S"]).flatMap(Int.init), wait >= 0 {
			cfg.accountPollWait = min(wait, 30)
		}
		if let urls = nonEmpty(env["WHISPERA_LINK_OFFER_BASE_URLS"]) {
			cfg.offerBaseURLs = urls.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
				.filter { !$0.isEmpty }
		}
		if let name = nonEmpty(env["WHISPERA_LINK_MAC_NAME"]) { cfg.macName = name }
		if let cli = env["WHISPERA_LINK_HERDR_CLI"] { cfg.herdrCLI = cli }
		if let seconds = nonEmpty(env["WHISPERA_LINK_APPROVAL_FALLBACK_S"]).flatMap(Double.init), seconds >= 0 {
			cfg.approvalFallback = seconds
		}
		if let seconds = nonEmpty(env["WHISPERA_LINK_REMOTE_POLL_S"]).flatMap(Double.init), seconds > 0 {
			cfg.remotePollInterval = seconds
		}
		if cfg.herdrCLI.hasPrefix("~") { cfg.herdrCLI = expand(cfg.herdrCLI, home) }
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
			case "herdr_cli": if let v = string(value) { herdrCLI = v }
			case "approval_fallback_s": if let v = double(value), v >= 0 { approvalFallback = v }
			case "remote_poll_s": if let v = double(value), v > 0 { remotePollInterval = v }
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
			case "account":
				guard let account = value as? [String: Any] else { continue }
				if let v = string(account["backend_url"]) { accountBackendURL = v }
				if let v = int("account.poll_wait_s", account["poll_wait_s"]) { accountPollWait = max(0, min(v, 30)) }
				if let v = account["offer_base_urls"] as? [String] { offerBaseURLs = v }
				if let v = string(account["mac_name"]) { macName = v }
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
		// gethostname, not ProcessInfo.hostName: the latter resolves the name over DNS and can
		// stall startup for half a minute on a network that does not answer.
		var buffer = [CChar](repeating: 0, count: 256)
		let name = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ""
		let short = name.split(separator: ".").first.map(String.init) ?? "localhost"
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
