import Foundation
import LinkHelperXPC

/// Answers the app over the helper's Mach service. Only the Developer ID-signed Whispera app may
/// connect (`LinkHelperXPC.clientRequirement`); unsigned development builds skip the check.
final class HelperXPCService: NSObject, NSXPCListenerDelegate, LinkHelperXPCProtocol, @unchecked Sendable {
	private let daemon: LinkDaemon
	private let requireSignedClient: Bool
	private var listener: NSXPCListener?

	init(daemon: LinkDaemon, requireSignedClient: Bool) {
		self.daemon = daemon
		self.requireSignedClient = requireSignedClient
	}

	func start() {
		let listener = NSXPCListener(machServiceName: LinkHelperXPC.machServiceName)
		listener.delegate = self
		if requireSignedClient { listener.setConnectionCodeSigningRequirement(LinkHelperXPC.clientRequirement) }
		listener.resume()
		self.listener = listener
	}

	func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
		connection.exportedInterface = NSXPCInterface(with: LinkHelperXPCProtocol.self)
		connection.exportedObject = self
		connection.resume()
		return true
	}

	func status(reply: @escaping (Data) -> Void) { reply(daemon.statusJSON()) }

	func pendingApprovals(reply: @escaping (Data) -> Void) { reply(daemon.pendingApprovalsJSON()) }

	func setAccount(_ request: Data, reply: @escaping (Data) -> Void) {
		let object = WireJSON.decodeObject(request) ?? [:]
		answer(reply) { [daemon] in
			try daemon.accountSet(
				bearer: object["bearer"] as? String ?? "", backendURL: object["backend_url"] as? String ?? "")
		}
	}

	func clearAccount(reply: @escaping (Data) -> Void) { answer(reply) { [daemon] in daemon.accountClear() } }

	func accountStatus(reply: @escaping (Data) -> Void) { answer(reply) { [daemon] in daemon.accountStatus() } }

	func pendingApproveConfirmations(reply: @escaping (Data) -> Void) {
		answer(reply) { [daemon] in daemon.approvePending() }
	}

	func confirmApprove(_ deviceID: String, safetyNumber: String, reply: @escaping (Data) -> Void) {
		answer(reply) { [daemon] in try daemon.approveConfirm(deviceID, safetyNumber: safetyNumber) }
	}

	/// Off the XPC queue: account calls wait on the network.
	private func answer(_ reply: @escaping (Data) -> Void, _ work: @escaping () throws -> [String: Any]) {
		DispatchQueue.global().async {
			do {
				reply(WireJSON.encode(try work()))
			} catch let error as APIError {
				reply(WireJSON.encode(error.adminObject))
			} catch {
				reply(
					WireJSON.encode([
						"ok": false, "error": ["code": LinkDaemon.errorCode(error), "message": "\(error.localizedDescription)"],
					]))
			}
		}
	}
}

/// `WhisperaLinkHelper serve`: the helper's whole life. Launched by launchd as a login item it
/// runs this with no arguments; the e2e scripts run it the same way with `WHISPERA_LINK_*` set.
public enum HelperRuntime {
	public static func serve(
		engine: LocalSpeechEngine?, environment: [String: String] = ProcessInfo.processInfo.environment
	) -> Int32 {
		let config = HelperConfig.load(environment: environment) {
			FileHandle.standardError.write(Data(("whispera-link: " + $0 + "\n").utf8))
		}
		let daemon: LinkDaemon
		do {
			daemon = try LinkDaemon(config: config, engine: engine)
			try daemon.start()
		} catch {
			FileHandle.standardError.write(
				Data("whispera-link: cannot start: \(error.localizedDescription)\n".utf8))
			return 1
		}
		let (url, warning) = config.effectivePublicURL(boundPort: daemon.port)
		if warning != nil, url == daemon.publicURL {
			FileHandle.standardError.write(Data("whispera-link: warning: \(warning!)\n".utf8))
		}
		if config.testSkipApprovePrecheck {
			FileHandle.standardError.write(
				Data(
					"whispera-link: WARNING test flag WHISPERA_LINK_TEST_SKIP_APPROVE_PRECHECK=1 is set\n"
						.utf8))
		}
		print(daemon.listeningLine())
		fflush(stdout)

		let xpc = HelperXPCService(daemon: daemon, requireSignedClient: isDeveloperIDSigned())
		#if DEBUG
			let xpcOff = environment["WHISPERA_LINK_XPC"] == "0"
		#else
			let xpcOff = false
		#endif
		if !xpcOff { xpc.start() }

		signal(SIGTERM, SIG_IGN)
		signal(SIGINT, SIG_IGN)
		let stop = DispatchSemaphore(value: 0)
		let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
			let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
			source.setEventHandler { stop.signal() }
			source.resume()
			return source
		}
		DispatchQueue.global().async {
			stop.wait()
			daemon.stop()
			_ = sources
			exit(0)
		}
		withExtendedLifetime(xpc) { RunLoop.main.run() }
		return 0
	}

	/// True when this process carries a Developer ID signature (QA and release builds).
	static func isDeveloperIDSigned() -> Bool {
		var code: SecCode?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
		var requirement: SecRequirement?
		guard
			SecRequirementCreateWithString(LinkHelperXPC.helperRequirement as CFString, [], &requirement)
				== errSecSuccess,
			let requirement
		else { return false }
		return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
	}
}
