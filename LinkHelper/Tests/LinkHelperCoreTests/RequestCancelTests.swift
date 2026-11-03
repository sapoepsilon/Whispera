import Foundation
import WhisperaLink
import WhisperaRecipes
import XCTest

@testable import LinkHelperCore

/// A phone that stops waiting stops the work: a closed connection or a relayed `api_cancel`
/// kills the subprocess and cancels the upstream call it started.
final class RequestCancelTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("wlc-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
	}

	/// A herdr CLI with one remote machine whose every command records its pid and hangs.
	private func slowCLI() throws -> (cli: String, pids: URL) {
		let pids = directory.appendingPathComponent("pids")
		let cli = directory.appendingPathComponent("herdr")
		let script = """
			#!/bin/sh
			if [ "$1 $2" = "machine list" ]; then echo '[{"id":"slow","label":"Slow Mac","enabled":true}]'; exit 0; fi
			echo $$ >> '\(pids.path)'
			exec /bin/sleep 30
			"""
		try Data(script.utf8).write(to: cli)
		chmod(cli.path, 0o755)
		return (cli.path, pids)
	}

	private static func firstPID(_ file: URL, timeout: TimeInterval = 10) -> pid_t? {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if let text = try? String(contentsOf: file, encoding: .utf8),
				let line = text.split(separator: "\n").first, let pid = pid_t(line)
			{ return pid }
			Thread.sleep(forTimeInterval: 0.02)
		}
		return nil
	}

	private static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

	/// Waits until `pid` is gone; answers how long that took.
	private static func waitGone(_ pid: pid_t, timeout: TimeInterval) -> TimeInterval? {
		let started = Date()
		while Date().timeIntervalSince(started) < timeout {
			if !isRunning(pid) { return Date().timeIntervalSince(started) }
			Thread.sleep(forTimeInterval: 0.01)
		}
		return nil
	}

	/// A signed request on a raw socket the test closes itself.
	private func openRequest(_ helper: TestDaemon, _ phone: SoftPhone, _ method: String, _ target: String, body: Data = Data())
		throws -> Int32
	{
		let request = try phone.signed(method, target, body: body)
		var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
		for (name, value) in request.allHTTPHeaderFields ?? [:] { head += "\(name): \(value)\r\n" }
		if method == "POST" { head += "Content-Length: \(body.count)\r\nContent-Type: application/json\r\n" }
		head += "\r\n"
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(UInt16(helper.port).bigEndian)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		XCTAssertEqual(connected, 0)
		var bytes = Data(head.utf8)
		bytes.append(body)
		_ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
		return fd
	}

	private func opsLog(_ helper: TestDaemon) -> String {
		(try? String(contentsOf: helper.directory.appendingPathComponent("helper.log"), encoding: .utf8)) ?? ""
	}

	private func waitForLog(_ helper: TestDaemon, _ needle: String, timeout: TimeInterval = 5) -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if opsLog(helper).contains(needle) { return true }
			Thread.sleep(forTimeInterval: 0.05)
		}
		return false
	}

	// MARK: Direct connection

	func testClosingTheConnectionKillsTheSpawnedProcessWithinASecond() async throws {
		let (cli, pids) = try slowCLI()
		let helper = try TestDaemon { $0.herdrCLI = cli }
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let fd = try openRequest(helper, phone, "GET", "/v1/agents/m_slow.w1:p1/output")
		let pid = try XCTUnwrap(Self.firstPID(pids), "the request reached the CLI")
		XCTAssertTrue(Self.isRunning(pid))
		Darwin.close(fd)
		let gone = try XCTUnwrap(Self.waitGone(pid, timeout: 3), "the hung CLI was killed")
		XCTAssertLessThan(gone, 1.0, "killed within a second of the close")
		XCTAssertTrue(waitForLog(helper, "http.cancelled"), opsLog(helper))
	}

	func testAConnectionThatStaysOpenIsNotCancelled() async throws {
		let helper = try TestDaemon()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let response = try await phone.call("GET", "/v1/devices/me")
		XCTAssertEqual(response.status, 200)
		XCTAssertFalse(opsLog(helper).contains("http.cancelled"))
	}

	func testClosingTheConnectionCancelsTheUpstreamSpeechRequest() async throws {
		let upstream = try HangingServer()
		defer { upstream.stop() }
		let selection = FixedSelection(.remote(RemoteSpeechServer(baseURL: upstream.baseURL, model: "m")))
		let helper = try TestDaemon(speechSelection: selection, speechKeys: MemorySpeechKeyStore())
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let (body, contentType) = TestAudio.multipart(Data(repeating: 1, count: 2048), fields: ["model": "whispera-mac"])
		let target = "/v1/audio/transcriptions"
		let signed = try SignedHeaders.sign(
			key: phone.linkKey, deviceID: phone.deviceID, method: "POST", target: target, body: body,
			timestamp: Int64(Date().timeIntervalSince1970), nonce: LinkCrypto.makeNonce())
		var signedRequest = URLRequest(url: helper.baseURL)
		signed.apply(to: &signedRequest)
		var head = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
		for (name, value) in signedRequest.allHTTPHeaderFields ?? [:] { head += "\(name): \(value)\r\n" }
		head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(UInt16(helper.port).bigEndian)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		_ = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		var bytes = Data(head.utf8)
		bytes.append(body)
		_ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
		XCTAssertTrue(upstream.waitForRequest(timeout: 5), "the helper called its speech server")
		Darwin.close(fd)
		let dropped = try XCTUnwrap(upstream.waitForDrop(timeout: 3), "the upstream request was cancelled")
		XCTAssertLessThan(dropped, 1.0)
		XCTAssertTrue(waitForLog(helper, "stt.cancelled"), opsLog(helper))
	}

	// MARK: Relay

	func testRelayCancelStopsALanguageModelRequest() async throws {
		let upstream = try HangingServer()
		defer { upstream.stop() }
		let domain = "RequestCancel.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		defaults.set(upstream.baseURL, forKey: "whisperaLocalServerURL")
		defaults.set("qa-model", forKey: "whisperaLocalModel")
		defaults.synchronize()
		let recipes = MacRecipeService(
			file: directory.appendingPathComponent("recipes.json"), domain: domain, keyStore: MemorySpeechKeyStore())
		let (helper, relay, _, _) = try await relayHelper(recipes: recipes)
		defer { helper.stop() }
		let account = helper.daemon.account

		let request = try relay.request("POST", "/v1/text/translate", json: ["text": "hola", "target_language": "en"])
		try await relay.send(request)
		_ = try await account.syncNow()
		XCTAssertTrue(upstream.waitForRequest(timeout: 5), "the helper called its LLM server")
		try await relay.cancel(request.id)
		_ = try await account.syncNow()
		let dropped = try XCTUnwrap(upstream.waitForDrop(timeout: 3), "api_cancel cancelled the upstream request")
		XCTAssertLessThan(dropped, 1.5)
		let deadline = Date().addingTimeInterval(3)
		while helper.daemon.relayIngress.activeCount > 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
		XCTAssertEqual(helper.daemon.relayIngress.activeCount, 0, "the handler returned")
		XCTAssertTrue(waitForLog(helper, "http.cancelled"), opsLog(helper))
		try await relay.drain()
		XCTAssertFalse(relay.frames(request.id).contains(where: \.final), "a cancelled request gets no answer")
	}

	/// A helper with an account phone pinned and confirmed, reached over the fake relay.
	private func relayHelper(recipes: MacRecipeService? = nil) async throws
		-> (TestDaemon, RelayPhone, AccountPhone, FakeAccountBackend)
	{
		let backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		let helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend, recipes: recipes) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
		}
		let account = helper.daemon.account
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: "Test iPhone")
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		_ = try await phone.receive()
		return (helper, RelayPhone(phone, macID: macID), phone, backend)
	}

	func testARelayedStreamEndsOnceItsPhoneGoesQuiet() async throws {
		let (helper, _, phone, backend) = try await relayHelper()
		defer { helper.stop() }
		let sender = try TrustedDevice(verifying: try XCTUnwrap(backend.device(phone.deviceID)))
		let ingress = RelayIngress(devices: helper.daemon.devices, streamLifetime: 600, streamIdleTimeout: 0.6)
		ingress.setHandler { exchange in
			try? exchange.beginStream(200, headers: [("Content-Type", "text/event-stream")])
			while exchange.isAlive {
				try? exchange.write(Data(": ping\n\n".utf8))
				Thread.sleep(forTimeInterval: 0.05)
			}
		}
		let sent = FrameLog()
		let quiet = RelayAPIRequest(method: "GET", target: "/v1/events", stream: true)
		ingress.accept(quiet, sender: sender) { sent.append($0) }
		// While the phone keeps talking, its stream stays up past the idle timeout.
		for _ in 0..<6 {
			try await Task.sleep(nanoseconds: 200_000_000)
			ingress.cancel(id: "unrelated-\(UUID().uuidString)", sender: sender.id)
		}
		XCTAssertFalse(sent.frames(quiet.id).contains(where: \.final), "a phone that is heard from keeps its stream")
		let deadline = Date().addingTimeInterval(3)
		while ingress.streamCount(sender: sender.id) > 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
		XCTAssertEqual(ingress.streamCount(sender: sender.id), 0, "a quiet phone's stream ends")
		XCTAssertTrue(sent.frames(quiet.id).last?.final ?? false, "with a clean end the phone can reopen")
	}

	// MARK: Token plumbing

	func testSpawnUnderACancelledTokenNeverStartsAndALateCancelKillsTheGroup() throws {
		let token = CancelToken()
		token.cancel("test")
		XCTAssertThrowsError(try CancelToken.with(token) { try HerdrCLI.spawn("/bin/sleep", ["5"], timeout: 10) }) {
			XCTAssertTrue($0 is RequestCancelled)
		}
		let live = CancelToken()
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { live.cancel("late") }
		let started = Date()
		XCTAssertThrowsError(try CancelToken.with(live) { try HerdrCLI.spawn("/bin/sh", ["-c", "sleep 20 & sleep 20"], timeout: 30) }) {
			XCTAssertTrue($0 is RequestCancelled)
		}
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
		XCTAssertEqual(try CancelToken.withoutCancellation { try CancelToken.with(nil) { try HerdrCLI.spawn("/bin/echo", ["ok"], timeout: 5) } }.status, 0)
	}

	func testStartInANewTabClosesTheTabWhenTheStartIsCancelled() throws {
		var control = AgentControl()
		control.sleep = { _ in }
		let token = CancelToken()
		var closed: [String] = []
		XCTAssertThrowsError(
			try CancelToken.with(token) {
				try control.startInNewTab(
					create: { ("t9", "p9") }, shellReady: { _ in true },
					start: { _ in
						token.cancel("phone left")
						return ["agent": ["id": "p9"]]
					},
					close: { closed.append($0) })
			}
		) { XCTAssertTrue($0 is RequestCancelled) }
		XCTAssertEqual(closed, ["t9"], "the tab the cancelled start opened is closed")
	}
}

/// An upstream (speech or LLM server) that never answers: it records when a request arrived
/// and when its connection went away.
final class HangingServer: @unchecked Sendable {
	private let server: HTTPServer
	private let lock = NSLock()
	private var arrived: Date?
	private var dropped: Date?
	let port: Int
	var baseURL: String { "http://127.0.0.1:\(port)/v1" }

	init() throws {
		let box = Box()
		server = HTTPServer(host: "127.0.0.1", port: 0, advertisement: nil) { box.handle?($0) }
		port = try server.start()
		box.handle = { [weak self] exchange in self?.hang(exchange) }
	}

	private final class Box: @unchecked Sendable { var handle: ((HTTPExchange) -> Void)? }

	private func hang(_ exchange: HTTPExchange) {
		let length = Int(exchange.header("Content-Length") ?? "0") ?? 0
		_ = try? exchange.readBody(length)
		lock.lock()
		arrived = Date()
		lock.unlock()
		exchange.watchForDisconnect()
		let deadline = Date().addingTimeInterval(30)
		while !exchange.cancelToken.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
		lock.lock()
		dropped = Date()
		lock.unlock()
	}

	func waitForRequest(timeout: TimeInterval) -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			lock.lock()
			let seen = arrived != nil
			lock.unlock()
			if seen { return true }
			Thread.sleep(forTimeInterval: 0.01)
		}
		return false
	}

	/// Seconds from now until the helper dropped the connection; nil when it never did.
	func waitForDrop(timeout: TimeInterval) -> TimeInterval? {
		let started = Date()
		while Date().timeIntervalSince(started) < timeout {
			lock.lock()
			let at = dropped
			lock.unlock()
			if at != nil { return Date().timeIntervalSince(started) }
			Thread.sleep(forTimeInterval: 0.01)
		}
		return nil
	}

	func stop() { server.stop() }
}
