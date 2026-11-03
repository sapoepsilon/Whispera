import CryptoKit
import Foundation
import LinkHelperXPC
import SystemConfiguration
import WhisperaHerdr
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
	/// Local and remote herdr agents (step 12).
	let agents: AgentDirectory
	/// Live terminals for the phone's terminal view.
	let terminals: TerminalBridge
	let remotePoller: RemoteAgentPoller
	let subscriber: HerdrSubscriber
	/// herdr-core's terminals (nil when configured off) and their event stream.
	let herdrCore: HerdrCoreDirectory?
	let hcSubscriber: HerdrCoreSubscriber?
	/// LinkAPI requests that arrive over the account relay (step 12).
	let relayIngress: RelayIngress
	let pushSealer: PushSealer
	let approvals: ApprovalsServer
	/// Blocked agents' permission dialogs (roadmap R1).
	let permissions: PermissionTracker
	/// Agents' interactive questions (AskUserQuestion, request_user_input), answered semantically.
	let asks: AskTracker
	/// Agents' conversations read from their own session logs.
	let transcripts: AgentTranscripts
	/// Agents waiting on the owner while herdr reports them idle (a scrolled-up view).
	let waits: AgentWaitWatch
	let startup: AgentStartup
	/// Phones' notification prefs (contract §4).
	let notificationPrefs: NotificationPrefsStore
	/// Agent turn/subagent/stop pushes (contract §2).
	let agentEvents: AgentEventNotifier
	let pairing: PairingManager
	let speech: SpeechService
    let recipes: MacRecipeService
	let push: PushNotifier
	let lastDevice: LastDeviceFile
	public let macApprovers: MacApproverStore
	public let macCard = MacCardOffer()
	public let daemonFP: String
	/// Signs every direct-path response with the daemon key (docs/LINK_RESPONSE_SIGNATURES.md).
	let responseSigner: ResponseSigner
	/// X9.63 base64 of the daemon key: what a link offer pins.
	public let daemonPubkeyB64: String
	/// Account pairing (step 11).
	public let account: AccountLink
	/// Zero-touch linking through the owner's already-trusted devices.
	public let circle: AccountCircle
	/// Who may connect directly (`DirectAccessPolicy`).
	public let directAccess: DirectAccessGate
	/// This Mac's MagicDNS name, which offers list first.
	let tailnetName: TailnetNameCache
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
	///   - engine: the Mac's own on-device speech engine.
	///   - speechSelection: which engine Whispera has selected; nil serves the configured
	///     upstream, else `engine` (the e2e daemon).
	///   - speechKeys: the speech server key Whispera handed over.
	///   - push: how approvals reach phones; nil picks the relay when `relay` is configured.
	///   - accountTransport: how the account backend is reached (a fake in tests).
	///   - tailnet: who is on the owner's tailnet; nil reads `config.tailscaleCLI` (a fake in tests).
	///   - recipes: the recipe service; nil reads Whispera's own settings and recipes file.
	///   - directAccess: whether plain-LAN peers get in; nil follows `config` alone.
	public init(
		config: HelperConfig, engine: LocalSpeechEngine?, push: PushNotifier? = nil,
		accountTransport: LinkTransport = URLSessionLinkTransport(), speechSelection: MacSpeechSelecting? = nil,
		speechKeys: SpeechKeyStoring? = nil, tailnet: TailnetIdentity? = nil, recipes: MacRecipeService? = nil,
		directAccess: DirectAccessGate? = nil
	) throws {
        self.recipes = recipes ?? MacRecipeService(domain: AppSpeechSelection.appDomain(helperBundleIdentifier: Bundle.main.bundleIdentifier))
		self.config = config
		let gate = directAccess ?? DirectAccessGate(configured: config.allowUnencryptedLAN)
		self.directAccess = gate
		let opsLog = OpsLog(path: config.paths.log, debug: config.logDebug)
		log = opsLog
		try FileStore.ensureDirectory(config.paths.stateDir)
		try FileStore.ensureDirectory(config.paths.keysDir)
		let key = try Self.loadOrCreateDaemonKey(config.paths.daemonKey, log: opsLog)
		let daemonPublic = LinkPublicKey(key.privateKey.publicKey)
		let daemonFP = daemonPublic.fingerprint
		responseSigner = ResponseSigner(key: key)
		let daemonPubkeyB64 = daemonPublic.x963Base64
		self.daemonFP = daemonFP
		self.daemonPubkeyB64 = daemonPubkeyB64
		let registry = try DeviceRegistry(path: config.paths.devices, keysDir: config.paths.keysDir)
		devices = registry
		herdr = HerdrClient(socketPath: config.herdrSocket)
		let hub = EventHub()
		self.hub = hub
		let startupBox = StartupBox()
		subscriber = HerdrSubscriber(
			socketPath: config.herdrSocket,
			emit: { hub.publish($0, startupBox.value?.correct($0, $1) ?? $1) }, log: opsLog)
		let core = config.hcSocket.isEmpty
			? nil
			: HerdrCoreDirectory(
				socketPath: config.hcSocket, cli: HerdrCLI.resolve(config.hcCLI, environment: ProcessInfo.processInfo.environment),
				log: opsLog)
		herdrCore = core
		hcSubscriber = core.map { HerdrCoreSubscriber(directory: $0, emit: { hub.publish($0, $1) }, log: opsLog) }
		let directory = AgentDirectory(local: herdr, cli: HerdrCLI(configured: config.herdrCLI, ssh: config.herdrSSH), log: opsLog, tmux: TmuxDirectory(configured: config.tmuxCLI, socket: config.tmuxSocket), hc: core)
		agents = directory
		terminals = TerminalBridge(config: config, herdr: herdr, log: { opsLog.log($0, $1) })
		terminals.herdrCore = core
		terminals.entitled = { LinkAPI.mayKeepStreaming(registry.get($0.deviceID), opened: $0) }
		remotePoller = RemoteAgentPoller(
			directory: directory, interval: config.remotePollInterval, isListening: { hub.streamCount() > 0 },
			emit: { hub.publish($0, $1) })
		let sealer = PushSealer()
		pushSealer = sealer
		let switchable = SwitchablePush(Self.relayPush(config: config, log: opsLog) ?? UnconfiguredPush())
		let notifier: PushNotifier = push ?? switchable
		self.push = notifier
		let lastDevice = LastDeviceFile(path: config.paths.lastDevice)
		self.lastDevice = lastDevice
		let macStore = MacApproverStore(stateDir: config.paths.stateDir)
		macApprovers = macStore
		let offer = macCard
		approvals = ApprovalsServer(
			socketPath: config.paths.approvalsSocket, devices: registry, publish: { hub.publish($0, $1) },
			push: notifier,
			log: opsLog, skipApprovePrecheck: config.testSkipApprovePrecheck, lastDevice: { lastDevice.current },
			macApprover: { macStore.current?.deviceRecord }, offerMacCard: { offer.offer(log: opsLog) })
		let herdrClient = herdr
		let transcriptStore = AgentTranscripts(
			readAgent: { pane in
				// herdr-core's terminals in the same shape, their Claude session from its pid.
				if HerdrCoreID.isHerdrCore(pane) { return try core?.transcriptInfo(pane) }
				return try herdrClient.rawAgent(pane)
			},
			readScreen: { try? directory.read($0, source: HerdrClient.visibleSource, lines: 80)["text"] as? String },
			statePath: config.paths.stateDir + "/transcripts.json",
			publish: { hub.publish($0, $1) },
			remote: directory.cli.sshPath == nil
				? nil
				: RemoteTranscripts(
					shell: { try directory.cli.shell(machine: $0, script: $1, timeout: $2) },
					readAgent: { try directory.remoteAgentInfo(machine: $0, pane: $1) },
					cacheDir: config.paths.stateDir + "/remote-transcripts", publish: { hub.publish($0, $1) }))
		transcripts = transcriptStore
		let waitWatch = AgentWaitWatch(
			hooks: AgentWaitWatch.Hooks(
				waiting: { transcriptStore.waiting($0) }, bind: { transcriptStore.ensureBound($0) },
				status: { id in
					let agent = try directory.get(id)["agent"] as? [String: Any] ?? [:]
					return (agent["status"] as? String ?? "unknown", agent)
				},
				screen: { try directory.read($0, source: HerdrClient.visibleSource, lines: 80)["text"] as? String ?? "" },
				scrollToBottom: { id in
					guard case .local(let pane) = AgentRef(id) else { return }
					try herdrClient.scrollToBottom(pane)
				}),
			publish: { hub.publish($0, $1) }, log: opsLog)
		waits = waitWatch
		let startupWatch = AgentStartup(
			hooks: AgentStartup.Hooks(
				raw: { try herdrClient.rawAgent($0) },
				screen: { try directory.read($0, source: HerdrClient.visibleSource, lines: 40)["text"] as? String ?? "" },
				turnOpen: { transcriptStore.ensureBound($0); return transcriptStore.turnOpen($0) }),
			publish: { hub.publish($0, $1) }, log: opsLog)
		startup = startupWatch
		startupBox.value = startupWatch
		hub.addListener { [waitWatch] event, data in waitWatch.observe(event, data) }
		permissions = PermissionTracker(
			reader: Self.permissionReader(directory, waits: waitWatch), publish: { hub.publish($0, $1) }, push: notifier,
			devices: { registry.active() }, lastDevice: { lastDevice.current }, log: opsLog)
		permissions.onApproved = { transcriptStore.noteApproved($0) }
		hub.addListener { [permissions] event, data in permissions.observe(event, data) }
		asks = AskTracker(
			reader: AskTracker.Reader(
				status: { id in
					let agent = try directory.get(id)["agent"] as? [String: Any] ?? [:]
					return (waitWatch.effective(id, agent["status"] as? String ?? "unknown"), agent)
				},
				terminal: { id in try directory.askTerminal(id) }),
			permissions: permissions, publish: { hub.publish($0, $1) }, push: notifier,
			devices: { registry.active() }, lastDevice: { lastDevice.current }, log: opsLog)
		hub.addListener { [asks] event, data in asks.observe(event, data) }
		let prefsStore = NotificationPrefsStore(path: config.paths.stateDir + "/notification-prefs.json")
		notificationPrefs = prefsStore
		let prefsFilter: (String, String, String) -> Bool = { prefsStore.allows($0, $1, agentID: $2) }
		permissions.pushFilter = prefsFilter
		asks.pushFilter = prefsFilter
		let eventSender: AgentEventSender = (notifier as? SwitchablePush) ?? UnconfiguredEventSender()
		let eventNotifier = AgentEventNotifier(
			hooks: AgentEventNotifier.Hooks(
				turnOpen: { id in
					guard case .local = AgentRef(id), !id.hasPrefix("tmux:") else { return nil }
					transcriptStore.ensureBound(id)
					return transcriptStore.turnOpen(id)
				},
				subagentsRunning: { id, info in
					var agent: [String: Any] = ["id": id]
					agent["agent"] = info["agent"]
					return transcriptStore.annotate(agent)["subagents_running"] as? Int ?? 0
				},
				exists: { id in
					do {
						_ = try directory.get(id)
						return true
					} catch let error as APIError where error.status == 404 {
						return false
					} catch {
						return nil
					}
				},
				describe: { id in try? directory.get(id)["agent"] as? [String: Any] }),
			sender: eventSender, sealer: sealer, devices: { registry.active() }, prefs: prefsStore, log: opsLog)
		agentEvents = eventNotifier
		hub.addListener { event, data in eventNotifier.observe(event, data) }
		speech = SpeechService(
			upstreamBaseURL: config.sttUpstreamBaseURL, upstreamKeyFile: config.sttUpstreamAPIKeyFile,
			upstreamModel: config.sttUpstreamModel, timeout: config.sttTimeout,
			engine: engine, selection: speechSelection, keyStore: speechKeys, log: opsLog)
		let ingress = RelayIngress(devices: registry, log: opsLog)
		relayIngress = ingress
		let urlBox = URLBox()
		self.urlBox = urlBox
		let portBox = URLBox()
		self.portBox = portBox
		let pairingConfig = config
		let identity: TailnetIdentity? = tailnet ?? TailscaleCLIIdentity(configured: config.tailscaleCLI)
		let tailnetName = TailnetNameCache(identity: identity)
		self.tailnetName = tailnetName
		pairing = PairingManager(
			devices: registry, daemonKey: key,
			publicURL: {
				// Before the listener is up there is no port to offer yet.
				guard let port = Int(portBox.value) else { return urlBox.value }
				return Self.pairingURL(
					pairingConfig, port: port, allowLAN: gate.allowsLAN, interfaces: gate.currentInterfaces,
					tailnetName: tailnetName.value)
			},
			defaultTTL: config.pairCodeTTL,
			log: opsLog, allowLAN: { gate.allowsLAN })
		registry.onRevoke { hub.closeDevice($0) }
		registry.onTrustLost { hub.closeDevice($0, reason: "unconfirmed") }
		let macName = config.macName.isEmpty ? Self.computerName() : config.macName
		let offerConfig = config
		let circle = AccountCircle(
			path: config.paths.circleState, tailnet: identity,
			defaultPort: config.port == 0 ? 7787 : config.port, log: opsLog)
		self.circle = circle
		account = AccountLink(
			paths: config.paths, devices: registry, push: switchable, transport: accountTransport,
			pollWait: config.accountPollWait, log: opsLog, ingress: ingress, pushSealer: sealer,
			approvalFallback: config.approvalFallback, circle: circle,
			offerContext: { [portBox] in
				let port = Int(portBox.value) ?? offerConfig.port
				let allowLAN = gate.allowsLAN
				return AccountLink.OfferContext(
					baseURLs: OfferAddresses.baseURLs(
						config: offerConfig, port: port, override: offerConfig.offerBaseURLs, allowLAN: allowLAN,
						interfaces: gate.currentInterfaces, tailnetName: tailnetName.value),
					daemonPubkeyB64: daemonPubkeyB64, daemonFP: daemonFP, macName: macName, allowLANHTTP: allowLAN)
			})
		api = LinkAPI(daemon: self)
		let api = self.api!
		ingress.setHandler { api.handle($0) }
	}

	/// The detection snapshot is the text herdr classified as blocked; a herdr (or another
	/// machine's) without that source gets the visible screen.
	static func permissionReader(_ directory: AgentDirectory, waits: AgentWaitWatch? = nil) -> PermissionTracker.Reader {
		PermissionTracker.Reader(
			status: { id in
				let agent = try directory.get(id)["agent"] as? [String: Any] ?? [:]
				let status = agent["status"] as? String ?? "unknown"
				return (waits?.effective(id, status) ?? status, agent)
			},
			screen: { id in
				if let read = try? directory.read(id, source: "detection", lines: 80) {
					return read["text"] as? String ?? ""
				}
				return try directory.read(id, source: HerdrClient.visibleSource, lines: 80)["text"] as? String ?? ""
			},
			sendKeys: { id, keys in _ = try directory.sendKeys(id, keys: keys) })
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
		return RelayPush(
			client: RelayClient(baseURL: base, deviceID: config.relayDeviceID, linkKey: key),
			fallbackAfter: config.approvalFallback, log: log)
	}

	public var publicURL: String {
		guard let port = Int(portBox.value) else { return urlBox.value }
		return Self.pairingURL(
			config, port: port, allowLAN: directAccess.allowsLAN, interfaces: directAccess.currentInterfaces,
			tailnetName: tailnetName.value)
	}

	/// A configured `public_url` as is; otherwise only an address the helper would admit.
	static func pairingURL(
		_ config: HelperConfig, port: Int, allowLAN: Bool, interfaces: [DirectAccessPolicy.InterfaceAddress]? = nil,
		tailnetName: String? = nil
	) -> String {
		if !AccountLink.trimmed(config.publicURL).isEmpty || HelperConfig.loopbackHosts.contains(config.listenHost) {
			return config.effectivePublicURL(boundPort: port).0
		}
		return OfferAddresses.pairingURL(
			config: config, port: port, allowLAN: allowLAN, interfaces: interfaces, tailnetName: tailnetName)
	}

	/// The user-visible computer name ("Sam's MacBook Pro"), without a DNS lookup.
	static func computerName() -> String {
		if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
		var buffer = [CChar](repeating: 0, count: 256)
		let host = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ""
		return host.split(separator: ".").first.map(String.init) ?? "Mac"
	}

	public var port: Int { http?.boundPort ?? 0 }

	func now() -> Int { Int(Date().timeIntervalSince1970) }

	/// herdr-core: `up`, `down`, `absent` (no capable core), or `off` (configured off).
	func hcState() -> String {
		guard let hcSubscriber else { return "off" }
		switch hcSubscriber.state {
		case .up: return "up"
		case .down: return "down"
		case .absent: return "absent"
		case .unknown: return herdrCore?.isAvailable == true ? "up" : "absent"
		}
	}

	func herdrState() -> String {
		switch subscriber.state {
		case .up: return "up"
		case .down: return "down"
		case .unknown: return (try? herdr.ping(timeout: 1)) != nil ? "up" : "down"
		}
	}

	/// The `_whispera._tcp` TXT record. `link_port` tells a phone which port pairs with this
	/// helper; without it the phone assumes 7787 and a helper on any other port is unreachable.
	/// `lan=1` while plain-LAN access is on: the phone may then use the address directly.
	static func bonjourTXT(port: Int, allowLAN: Bool = false) -> [String: String] {
		// What a phone needs to connect, nothing that identifies this Mac: the key is pinned
		// from the pairing code's QR or the account offer, never from mDNS.
		var txt = ["path": "/v1", "scheme": "http", "v": "1"]
		if (1...65535).contains(port) { txt["link_port"] = String(port) }
		if allowLAN { txt["lan"] = "1" }
		return txt
	}

	/// Bonjour lives on the local network, so the helper is advertised only while plain-LAN access
	/// is on: a tailnet peer finds the Mac through its offer, not mDNS.
	var shouldAdvertise: Bool {
		config.bonjour && !HelperConfig.loopbackHosts.contains(config.listenHost) && directAccess.allowsLAN
	}

	private var advertisement: HTTPServer.Advertisement {
		HTTPServer.Advertisement(
			type: Self.bonjourType, txt: Self.bonjourTXT(port: config.port, allowLAN: directAccess.allowsLAN))
	}

	private var advertisementTimer: DispatchSourceTimer?

	/// Follows the setting while the helper runs, so turning it on or off in Whispera starts or
	/// stops the advertisement within a few seconds.
	private func watchAdvertisement(_ server: HTTPServer, advertised: Bool) {
		guard config.bonjour, !HelperConfig.loopbackHosts.contains(config.listenHost) else { return }
		let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "link.bonjour.watch"))
		var current = advertised
		timer.schedule(deadline: .now() + 5, repeating: 5)
		timer.setEventHandler { [weak self, weak server] in
			guard let self, let server else { return }
			let wanted = self.shouldAdvertise
			guard wanted != current else { return }
			current = wanted
			server.setAdvertisement(wanted ? self.advertisement : nil)
			self.log("bonjour", ["detail": wanted ? "advertising" : "stopped: plain-LAN access is off"])
		}
		timer.resume()
		advertisementTimer = timer
	}

	/// Starts every listener. Returns the bound HTTP port.
	@discardableResult
	public func start() throws -> Int {
		let api = self.api!
		let advertised = shouldAdvertise
		let server = HTTPServer(
			host: config.listenHost, port: config.port, advertisement: advertised ? advertisement : nil,
			handler: { api.handle($0) })
		server.onServiceRegistration = { [log] change in log("bonjour", ["detail": change]) }
		let gate = directAccess
		server.admit = { gate.admits(peer: $0, local: $1, interface: $2) }
		let refusals = RateLimiter(limit: 0, window: 60, blockFor: 60)
		server.responseSigner = responseSigner
		server.onRefused = { [log] peer in
			// One line per peer per minute: a scanner on the LAN must not flood the log.
			guard !refusals.isBlocked(peer) else { return }
			refusals.fail(peer)
			log("http.refused", ["detail": "direct connection from \(peer): not loopback or this Mac's tailnet address"])
		}
		let busy = RateLimiter(limit: 0, window: 60, blockFor: 60)
		let (perPeer, total) = (server.connections.perPeer, server.connections.total)
		server.onBusy = { [log] peer in
			guard !busy.isBlocked(peer) else { return }
			busy.fail(peer)
			log(
				"http.busy",
				[
					"detail":
						"direct connection from \(peer) refused: over \(perPeer) per peer or \(total) in total"
				])
		}
		let port = try server.start()
		http = server
		tailnetName.refresh()
		watchAdvertisement(server, advertised: advertised)
		let (url, warning) = config.effectivePublicURL(boundPort: port)
		urlBox.value = url
		portBox.value = String(port)
		if let warning { log("config.warning", ["detail": warning]) }
		if config.testSkipApprovePrecheck { log("config.warning", ["detail": "test_skip_approve_precheck"]) }
		try approvals.start()
		// Each handler runs only while the daemon is alive: one that arrives as it goes away is refused.
		let handlers = adminHandlers().mapValues { handler -> AdminServer.Handler in
			{ [weak self] request in
				guard let self else { throw APIError(503, "unavailable", "the helper is stopping") }
				return try withExtendedLifetime(self) { try handler(request) }
			}
		}
		let admin = AdminServer(socketPath: config.paths.adminSocket, handlers: handlers, log: log)
		try admin.start()
		self.admin = admin
		subscriber.start()
		hcSubscriber?.start()
		remotePoller.start()
		transcripts.start()
		waits.start()
		agentEvents.start()
		startup.start()
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
		advertisementTimer?.cancel()
		advertisementTimer = nil
		circle.stop()
		Task { [account] in await account.stop() }
		hub.closeAll()
		terminals.closeAll()
		http?.stop()
		admin?.stop()
		approvals.stop()
		subscriber.stop()
		hcSubscriber?.stop()
		remotePoller.stop()
		transcripts.stop()
		waits.stop()
		agentEvents.stop()
		startup.stop()
		log("stop")
	}

	public func status() -> HelperStatus {
		HelperStatus(
			ok: true, version: Self.version, protocol: Self.protocolVersion, pid: getpid(), port: port,
			publicURL: publicURL,
			daemonFP: daemonFP, herdr: herdrState(), broker: approvals.isConnected ? "connected" : "idle",
			apns: push.isConfigured ? "configured" : "unconfigured",
			stt: speech.isConfigured ? "configured" : "unconfigured",
			sttMode: speech.mode, sttModels: speech.localModels, sttEngine: speech.engineInfo().name,
			devices: devices.activeCount,
			pendingApprovals: approvals.pendingCount, macApprover: macApprovers.current?.deviceID)
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
		guard var status = try? blocking(5, { [account] in await account.statusObject() }) else { return ["ok": false] }
		let last = lastDevice.current
		status["last_device"] = last ?? NSNull()
		// Per iPhone: what its approval pushes say and whether it made the latest request.
		status["phone_details"] = devices.active().filter { $0.origin == .account }.map {
			["device_id": $0.deviceID, "push_text": $0.pushText.rawValue, "last_used": $0.deviceID == last]
				as [String: Any]
		}
		return status
	}

	func accountClear() -> [String: Any] {
		(try? blocking { [account] in await account.disconnect() }) ?? ["ok": false]
	}

	func accountSync() throws -> [String: Any] {
		try blocking { [account] in
			let report = try await account.syncNow()
			return [
				"ok": true, "pinned": report.pinned, "offered": report.offered, "dropped": report.dropped,
				"untrusted": report.untrusted, "key_changed": report.keyChanged,
			]
		}
	}

	func approvePending() -> [String: Any] {
		(try? blocking(5, { [account] in ["ok": true, "devices": await account.pendingConfirmations()] }))
			?? ["ok": true, "devices": [Any]()]
	}

	/// `safetyNumber` is the one the owner compared; the helper recomputes it from the device's
	/// current keys and refuses (409 `keys_changed`) when they differ.
	func approveConfirm(_ deviceID: String, safetyNumber: String) throws -> [String: Any] {
		try blocking { [account] in try await account.confirmApprove(deviceID, safetyNumber: safetyNumber) }
	}

	func approveConfirmVouched(_ deviceID: String, linkFingerprint: String, vouchedBy: String) throws -> [String: Any] {
		try blocking { [account] in
			try await account.confirmVouched(deviceID, linkFingerprint: linkFingerprint, vouchedBy: vouchedBy)
		}
	}

	func linkPending() -> [String: Any] {
		(try? blocking(5, { [account] in
			[
				"ok": true, "links": await account.pendingLinks(), "linked": await account.linkedMacs(),
				"moved": await account.movedMacs(),
			]
		})) ?? ["ok": false]
	}

	/// `decision`: `approve` (after the owner's Touch ID in the app) or `decline`.
	func linkDecide(
		_ deviceID: String, decision: String, tailnetName: String, linkFingerprint: String, name: String = "",
		nodeID: String = ""
	) throws -> [String: Any] {
		guard ["approve", "decline", "relink"].contains(decision) else {
			throw APIError(400, "bad_request", "decision must be approve, decline or relink")
		}
		return try blocking { [account] in
			try await account.decideLink(
				deviceID, approve: decision == "approve", tailnetName: tailnetName, linkFingerprint: linkFingerprint,
				name: name, nodeID: nodeID, relink: decision == "relink")
		}
	}

	// MARK: Mac approval card (§8.1)

	/// `GET /v1/approvals/{id}`'s body, or `{"error":{…}}`.
	public func approvalJSON(_ requestID: String) -> Data {
		do {
			return WireJSON.encode(try approvals.get(requestID))
		} catch {
			return Self.errorJSON(error)
		}
	}

	/// The card's decision: `{"request_id","status","broker_outcome"}` or `{"error":{…}}`.
	public func decideFromMacJSON(_ requestID: String, decision: String, signature: String?) -> Data {
		do {
			let reply = try approvals.decideFromMac(requestID, decision: decision, signature: signature)
			log("approval.mac_decision", ["request_id": requestID, "detail": "decision=\(decision)"])
			return WireJSON.encode(reply)
		} catch {
			return Self.errorJSON(error)
		}
	}

	/// Stores (or, with `{}`, removes) the card's approve key; answers `macApproverJSON()`.
	public func enrollMacApproverJSON(_ body: Data) -> Data {
		do {
			guard let request = WireJSON.decodeObject(body) else {
				throw APIError(400, "bad_request", "expected a JSON object")
			}
			let approver = try macApprovers.enroll(request, now: now())
			log("mac_approver.\(approver == nil ? "removed" : "enrolled")", ["device": approver?.deviceID ?? "-"])
			return macApproverJSON()
		} catch {
			return Self.errorJSON(error)
		}
	}

	/// `{"mac_approver":{…}|null,"pem_path":…}`.
	public func macApproverJSON() -> Data {
		WireJSON.encode([
			"mac_approver": macApprovers.current?.json as Any? ?? NSNull(), "pem_path": macApprovers.pemPath,
		])
	}

	static func errorJSON(_ error: Error) -> Data {
		guard let api = error as? APIError else {
			return WireJSON.encode(["error": ["code": "internal", "message": error.localizedDescription]])
		}
		var body: [String: Any] = ["code": api.code, "message": api.message]
		for (key, value) in api.extra where body[key] == nil { body[key] = value }
		return WireJSON.encode(["error": body])
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
			"approve.confirm_vouched": { [unowned self] request in
				guard config.testAdminConfirm else {
					throw APIError(403, "forbidden", "approve.confirm_vouched needs WHISPERA_LINK_TEST_ADMIN_CONFIRM=1 (test only)")
				}
				return try approveConfirmVouched(
					request["device_id"] as? String ?? "", linkFingerprint: request["link_fingerprint"] as? String ?? "",
					vouchedBy: request["vouched_by"] as? String ?? "")
			},
			"link.pending": { [unowned self] _ in linkPending() },
			"link.decide": { [unowned self] request in
				// Touch ID lives in the app; deciding here (either way: a decline unlinks) exists for
				// automated tests only.
				guard config.testAdminConfirm else {
					throw APIError(403, "forbidden", "link.decide needs WHISPERA_LINK_TEST_ADMIN_CONFIRM=1 (test only)")
				}
				return try linkDecide(
					request["device_id"] as? String ?? "", decision: request["decision"] as? String ?? "",
					tailnetName: request["tailnet_name"] as? String ?? "",
					linkFingerprint: request["link_fingerprint"] as? String ?? "", name: request["name"] as? String ?? "",
					nodeID: request["node_id"] as? String ?? "")
			},
			"approve.confirm": { [unowned self] request in
				// Touch ID lives in the app; this path exists for automated tests only.
				guard config.testAdminConfirm else {
					throw APIError(
						403, "forbidden", "approve.confirm needs WHISPERA_LINK_TEST_ADMIN_CONFIRM=1 (test only)")
				}
				log("config.warning", ["detail": "approve confirmed over the admin socket (test flag)"])
				return try approveConfirm(
					request["device_id"] as? String ?? "", safetyNumber: request["safety_number"] as? String ?? "")
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
				var reply: [String: Any] = ["ok": true, "device": record.publicJSON]
				// An account phone is revoked on the backend too (and this Mac's vouch for it is
				// withdrawn); the local revoke above stands whatever that answers.
				if record.origin == .account {
					let bearer = request["bearer"] as? String
					let outcome = (try? blocking(30) { [account] in await account.revokeInAccount(id, bearer: bearer).json })
					reply["account_revoke"] =
						outcome ?? ["ok": false, "error": ["code": "timed_out", "message": "account revoke timed out"], "queued": true]
				}
				return reply
			},
			"apns.reload": { [unowned self] _ in
				["ok": true, "apns": push.isConfigured ? "configured" : "unconfigured"]
			},
			"apns.test": { [unowned self] _ in
				let status = push.notifyApproval(
					ApprovalPush(
						requestID: LinkCrypto.newPrefixedID("apr"), expiresAt: now() + 60,
						lastDevice: lastDevice.current, summary: "test push"),
					devices: devices.active().filter(\.approveConfirmed), isPending: { false })
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

/// Whether a Mac approval card can show for a new request, and how to get one up: the app is
/// either already watching over XPC or the helper launches it (§8.1).
public final class MacCardOffer: @unchecked Sendable {
	private let lock = NSLock()
	private var watching: () -> Bool = { false }
	private var launch: (() -> Void)?

	public init() {}

	public func configure(watching: @escaping () -> Bool, launch: (() -> Void)?) {
		lock.lock()
		self.watching = watching
		self.launch = launch
		lock.unlock()
	}

	func offer(log: OpsLog) -> Bool {
		lock.lock()
		let watching = self.watching
		let launch = self.launch
		lock.unlock()
		if watching() { return true }
		guard let launch else { return false }
		log("mac_card.launch")
		launch()
		return true
	}
}

/// Lets the herdr subscriber, made first, reach the startup watch made after it.
private final class StartupBox: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: AgentStartup?
	var value: AgentStartup? {
		get { lock.lock(); defer { lock.unlock() }; return stored }
		set { lock.lock(); stored = newValue; lock.unlock() }
	}
}

/// This Mac's MagicDNS name from the Tailscale CLI, refreshed in the background at most once a
/// minute so building an offer never waits on the CLI.
final class TailnetNameCache: @unchecked Sendable {
	private let identity: TailnetIdentity?
	private let lock = NSLock()
	private var cached: String?
	private var fetchedAt: Date?
	private var refreshing = false

	init(identity: TailnetIdentity?) {
		self.identity = identity
	}

	var value: String? {
		lock.lock()
		let stale = fetchedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
		let current = cached
		lock.unlock()
		if stale { refresh() }
		return current
	}

	func refresh() {
		guard let identity else { return }
		lock.lock()
		if refreshing {
			lock.unlock()
			return
		}
		refreshing = true
		lock.unlock()
		DispatchQueue.global(qos: .utility).async { [self] in
			let name = identity.selfDNSName()
			lock.lock()
			cached = name
			fetchedAt = Date()
			refreshing = false
			lock.unlock()
		}
	}

	/// Tests: the name as if the CLI had answered.
	func set(_ name: String?) {
		lock.lock()
		cached = name
		fetchedAt = Date()
		lock.unlock()
	}
}
