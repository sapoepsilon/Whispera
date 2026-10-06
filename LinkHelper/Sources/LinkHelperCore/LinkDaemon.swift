import CryptoKit
import Foundation
import LinkHelperXPC
import SystemConfiguration
import WhisperaLink

/// The whole helper, wired once (PROTOCOL §1.2: cross-module wiring happens only here).
public final class LinkDaemon: @unchecked Sendable {
	public static let version = "0.2.0"
	public static let protocolVersion = 1
	public static let bonjourType = "_whispera._tcp"

	public let config: HelperConfig
	let log: OpsLog
	let devices: DeviceRegistry
	let hub: EventHub
	let herdr: HerdrClient
	let subscriber: HerdrSubscriber
	let approvals: ApprovalsServer
	let pairing: PairingManager
	let speech: SpeechService
	let push: PushNotifier
	let lastDevice: LastDeviceFile
	public let daemonFP: String
	/// X9.63 base64 of the daemon key: what a link offer pins.
	public let daemonPubkeyB64: String
	/// Account pairing (step 11).
	public let account: AccountLink
	private var api: LinkAPI!
	private var http: HTTPServer?
	private var admin: AdminServer?
	private let urlBox: URLBox
	/// The bound HTTP port, for link offers built off the main thread.
	private let portBox: URLBox

	private final class URLBox: @unchecked Sendable {
		private let lock = NSLock()
		private var stored = ""
		var value: String {
			get {
				lock.lock()
				defer { lock.unlock() }
				return stored
			}
			set {
				lock.lock()
				stored = newValue
				lock.unlock()
			}
		}
	}

	/// - Parameters:
	///   - engine: the Mac's own speech engine; answers `/v1/audio/transcriptions` when no
	///     upstream is configured.
	///   - push: how approvals reach phones; nil picks the relay when `relay` is configured.
	///   - accountTransport: how the account backend is reached (a fake in tests).
	public init(
		config: HelperConfig, engine: LocalSpeechEngine?, push: PushNotifier? = nil,
		accountTransport: LinkTransport = URLSessionLinkTransport()
	) throws {
		self.config = config
		let opsLog = OpsLog(path: config.paths.log, debug: config.logDebug)
		log = opsLog
		try FileStore.ensureDirectory(config.paths.stateDir)
		try FileStore.ensureDirectory(config.paths.keysDir)
		let key = try Self.loadOrCreateDaemonKey(config.paths.daemonKey, log: opsLog)
		let daemonPublic = LinkPublicKey(key.privateKey.publicKey)
		let daemonFP = daemonPublic.fingerprint
		let daemonPubkeyB64 = daemonPublic.x963Base64
		self.daemonFP = daemonFP
		self.daemonPubkeyB64 = daemonPubkeyB64
		let registry = try DeviceRegistry(path: config.paths.devices, keysDir: config.paths.keysDir)
		devices = registry
		herdr = HerdrClient(socketPath: config.herdrSocket)
		let hub = EventHub()
		self.hub = hub
		subscriber = HerdrSubscriber(socketPath: config.herdrSocket, emit: { hub.publish($0, $1) }, log: opsLog)
		let switchable = SwitchablePush(Self.relayPush(config: config, log: opsLog) ?? UnconfiguredPush())
		let notifier: PushNotifier = push ?? switchable
		self.push = notifier
		approvals = ApprovalsServer(
			socketPath: config.paths.approvalsSocket, devices: registry, publish: { hub.publish($0, $1) },
			push: notifier,
			log: opsLog, skipApprovePrecheck: config.testSkipApprovePrecheck)
		speech = SpeechService(
			upstreamBaseURL: config.sttUpstreamBaseURL, upstreamKeyFile: config.sttUpstreamAPIKeyFile,
			timeout: config.sttTimeout,
			engine: engine, log: opsLog)
		lastDevice = LastDeviceFile(path: config.paths.lastDevice)
		let urlBox = URLBox()
		self.urlBox = urlBox
		let portBox = URLBox()
		self.portBox = portBox
		pairing = PairingManager(
			devices: registry, daemonKey: key, publicURL: { urlBox.value }, defaultTTL: config.pairCodeTTL,
			log: opsLog)
		registry.onRevoke { hub.closeDevice($0) }
		let macName = config.macName.isEmpty ? Self.computerName() : config.macName
		let offerConfig = config
		account = AccountLink(
			paths: config.paths, devices: registry, push: switchable, transport: accountTransport,
			pollWait: config.accountPollWait, log: opsLog,
			offerContext: { [portBox] in
				let port = Int(portBox.value) ?? offerConfig.port
				return AccountLink.OfferContext(
					baseURLs: OfferAddresses.baseURLs(config: offerConfig, port: port, override: offerConfig.offerBaseURLs),
					daemonPubkeyB64: daemonPubkeyB64, daemonFP: daemonFP, macName: macName)
			})
		api = LinkAPI(daemon: self)
	}

	static func loadOrCreateDaemonKey(_ path: String, log: OpsLog) throws -> SoftwareSigningKey {
		if let pem = try? String(contentsOfFile: path, encoding: .utf8) {
			chmod(path, 0o600)
			return try SoftwareSigningKey(pkcs8PEM: pem)
		}
		let key = P256.Signing.PrivateKey()
		try FileStore.writeAtomic(Data((key.pemRepresentation + "\n").utf8), to: path)
		log("daemon_key.created")
		return SoftwareSigningKey(key)
	}

	/// The backend's notify endpoint, once the Mac has a relay identity (accounts, step 11).
	static func relayPush(config: HelperConfig, log: OpsLog) -> PushNotifier? {
		guard let base = URL(string: config.relayBaseURL), !config.relayBaseURL.isEmpty,
			LinkCrypto.isValidDeviceID(config.relayDeviceID),
			let pem = try? String(contentsOfFile: config.paths.relayKey, encoding: .utf8),
			let key = try? SoftwareSigningKey(pkcs8PEM: pem)
		else { return nil }
		return RelayPush(client: RelayClient(baseURL: base, deviceID: config.relayDeviceID, linkKey: key), log: log)
	}

	public var publicURL: String { urlBox.value }

	/// The user-visible computer name ("Uzi's MacBook Pro"), without a DNS lookup.
	static func computerName() -> String {
		if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
		var buffer = [CChar](repeating: 0, count: 256)
		let host = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ""
		return host.split(separator: ".").first.map(String.init) ?? "Mac"
	}

	public var port: Int { http?.boundPort ?? 0 }

	func now() -> Int { Int(Date().timeIntervalSince1970) }

	func herdrState() -> String {
		switch subscriber.state {
		case .up: return "up"
		case .down: return "down"
		case .unknown: return (try? herdr.ping(timeout: 1)) != nil ? "up" : "down"
		}
	}

	/// Starts every listener. Returns the bound HTTP port.
	@discardableResult
	public func start() throws -> Int {
		let advertise = config.bonjour && !HelperConfig.loopbackHosts.contains(config.listenHost)
		let api = self.api!
		let server = HTTPServer(
			host: config.listenHost, port: config.port,
			advertisement: advertise
				? HTTPServer.Advertisement(
					type: Self.bonjourType,
					txt: ["path": "/v1", "scheme": "http", "v": "1", "fp": String(daemonFP.prefix(16))])
				: nil,
			handler: { api.handle($0) })
		server.onServiceRegistration = { [log] change in log("bonjour", ["detail": change]) }
		let port = try server.start()
		http = server
		let (url, warning) = config.effectivePublicURL(boundPort: port)
		urlBox.value = url
		portBox.value = String(port)
		if let warning { log("config.warning", ["detail": warning]) }
		if config.testSkipApprovePrecheck { log("config.warning", ["detail": "test_skip_approve_precheck"]) }
		try approvals.start()
		let admin = AdminServer(socketPath: config.paths.adminSocket, handlers: adminHandlers(), log: log)
		try admin.start()
		self.admin = admin
		subscriber.start()
		Task { [account] in await account.start() }
		if !config.accountBearer.isEmpty, let backend = URL(string: config.accountBackendURL.isEmpty ? config.relayBaseURL : config.accountBackendURL) {
			// Standalone/e2e: join the account from the environment, as the app's XPC call would.
			let bearer = config.accountBearer
			Task { [account, log] in
				do {
					_ = try await account.connect(bearer: bearer, backendURL: backend)
				} catch {
					log("account.connect_failed", ["detail": Self.errorCode(error)])
				}
			}
		}
		log(
			"serve",
			["detail": "listening \(config.listenHost):\(port) fp=\(daemonFP.prefix(16)) stt=\(speech.mode)"])
		return port
	}

	public func stop() {
		Task { [account] in await account.stop() }
		hub.closeAll()
		http?.stop()
		admin?.stop()
		approvals.stop()
		subscriber.stop()
		log("stop")
	}

	public func status() -> HelperStatus {
		HelperStatus(
			ok: true, version: Self.version, protocol: Self.protocolVersion, pid: getpid(), port: port,
			publicURL: publicURL,
			daemonFP: daemonFP, herdr: herdrState(), broker: approvals.isConnected ? "connected" : "idle",
			apns: push.isConfigured ? "configured" : "unconfigured",
			stt: speech.isConfigured ? "configured" : "unconfigured",
			sttMode: speech.mode, sttModels: speech.localModels, devices: devices.activeCount,
			pendingApprovals: approvals.pendingCount)
	}

	public func statusJSON() -> Data {
		(try? JSONEncoder().encode(status())) ?? Data("{}".utf8)
	}

	public func pendingApprovalsJSON() -> Data {
		WireJSON.encode(["approvals": approvals.pending()])
	}

	static func errorCode(_ error: Error) -> String {
		(error as? APIError)?.code ?? (error as? LinkError)?.code ?? "\(type(of: error))"
	}

	/// Runs an account call to completion for a synchronous caller (admin socket, XPC bridge).
	func blocking(_ timeout: TimeInterval = 60, _ work: @escaping @Sendable () async throws -> [String: Any])
		throws -> [String: Any]
	{
		let box = BlockingBox()
		let done = DispatchSemaphore(value: 0)
		Task {
			do {
				box.result = .success(try await work())
			} catch {
				box.result = .failure(error)
			}
			done.signal()
		}
		guard done.wait(timeout: .now() + timeout) == .success, let result = box.result else {
			throw APIError(504, "timed_out", "account call timed out")
		}
		return try result.get()
	}

	private final class BlockingBox: @unchecked Sendable {
		var result: Result<[String: Any], Error>?
	}

	/// Account calls shared by the admin socket and XPC. Each answers a JSON object.
	func accountSet(bearer: String, backendURL: String) throws -> [String: Any] {
		guard let url = URL(string: backendURL.isEmpty ? (config.accountBackendURL.isEmpty ? config.relayBaseURL : config.accountBackendURL) : backendURL),
			!url.absoluteString.isEmpty
		else { throw APIError(400, "bad_request", "backend_url is required") }
		return try blocking { [account] in try await account.connect(bearer: bearer, backendURL: url) }
	}

	func accountStatus() -> [String: Any] {
		(try? blocking(5) { [account] in await account.statusObject() }) ?? ["ok": false]
	}

	func accountClear() -> [String: Any] {
		(try? blocking { [account] in await account.disconnect() }) ?? ["ok": false]
	}

	func accountSync() throws -> [String: Any] {
		try blocking { [account] in
			let report = try await account.syncNow()
			return [
				"ok": true, "pinned": report.pinned, "offered": report.offered, "dropped": report.dropped,
				"untrusted": report.untrusted,
			]
		}
	}

	func approvePending() -> [String: Any] {
		["ok": true, "devices": devices.pendingApproveConfirmations().map(AccountLink.confirmationObject)]
	}

	func approveConfirm(_ deviceID: String) throws -> [String: Any] {
		try blocking { [account] in try await account.confirmApprove(deviceID) }
	}

	private func adminHandlers() -> [String: AdminServer.Handler] {
		[
			"account.set": { [unowned self] request in
				try accountSet(
					bearer: request["bearer"] as? String ?? "", backendURL: request["backend_url"] as? String ?? "")
			},
			"account.status": { [unowned self] _ in accountStatus() },
			"account.sync": { [unowned self] _ in try accountSync() },
			"account.clear": { [unowned self] _ in accountClear() },
			"approve.pending": { [unowned self] _ in approvePending() },
			"approve.confirm": { [unowned self] request in
				// Touch ID lives in the app; this path exists for automated tests only.
				guard config.testAdminConfirm else {
					throw APIError(
						403, "forbidden", "approve.confirm needs WHISPERA_LINK_TEST_ADMIN_CONFIRM=1 (test only)")
				}
				log("config.warning", ["detail": "approve confirmed over the admin socket (test flag)"])
				return try approveConfirm(request["device_id"] as? String ?? "")
			},
			"status": { [unowned self] _ in
				(try JSONSerialization.jsonObject(with: statusJSON()) as? [String: Any]) ?? ["ok": true]
			},
			"pair.begin": { [unowned self] request in pairing.begin(ttl: WireJSON.strictInt(request["ttl_s"])) },
			"pair.wait": { [unowned self] request in
				let timeout = (request["timeout_s"] as? NSNumber)?.doubleValue ?? 300
				return [
					"ok": true,
					"device": try pairing.wait(code: request["code"] as? String ?? "", timeout: timeout),
				]
			},
			"devices.list": { [unowned self] _ in ["ok": true, "devices": devices.all().map(\.publicJSON)] },
			"devices.revoke": { [unowned self] request in
				guard let id = request["device_id"] as? String, let record = devices.revoke(id) else {
					return ["ok": false, "error": ["code": "not_found", "message": "no such device"]]
				}
				log("device.revoked", ["device": id, "detail": "admin"])
				return ["ok": true, "device": record.publicJSON]
			},
			"apns.reload": { [unowned self] _ in
				["ok": true, "apns": push.isConfigured ? "configured" : "unconfigured"]
			},
			"apns.test": { [unowned self] _ in
				let status = push.notifyApproval(
					requestID: "test", expiresAt: now() + 60, preferDevice: nil, devices: devices.active())
				return [
					"ok": true, "apns": push.isConfigured ? "configured" : "unconfigured",
					"results": ["all": status],
				]
			},
		]
	}

	/// The line `whispera-link serve` prints once listening; the e2e scripts wait for it.
	public func listeningLine() -> String {
		"whispera-link \(Self.version) listening host=\(config.listenHost) port=\(port) url=\(publicURL) fp=\(daemonFP)"
	}
}
