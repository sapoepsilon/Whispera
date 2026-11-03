import Foundation
import Network
import XCTest

@testable import LinkHelperCore

/// A loopback TCP server that answers each request with scripted raw bytes, so the peer client
/// sees exactly the responses (well-formed or not) a test describes.
final class RawHTTPServer: @unchecked Sendable {
	enum Step {
		case send(Data)
		case wait(TimeInterval)
		/// Ends the script with the connection left open (a peer that stalls).
		case hang
	}

	private let listener: NWListener
	private let queue = DispatchQueue(label: "test.raw-http")
	private let lock = NSLock()
	private var script: [String: [Step]] = [:]
	private var open: [NWConnection] = []
	private(set) var connections = 0
	private(set) var requests: [String] = []
	private(set) var port = 0

	init() throws {
		let parameters = NWParameters.tcp
		parameters.requiredInterfaceType = .loopback
		listener = try NWListener(using: parameters, on: .any)
		let ready = DispatchSemaphore(value: 0)
		listener.stateUpdateHandler = { state in
			if case .ready = state { ready.signal() }
		}
		listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
		listener.start(queue: queue)
		guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
			throw NSError(domain: "RawHTTPServer", code: 1)
		}
		port = Int(bound)
	}

	func on(_ path: String, _ steps: [Step]) { lock.withLock { script[path] = steps } }
	func on(_ path: String, raw: String) { on(path, [.send(Data(raw.utf8))]) }

	var connectionCount: Int { lock.withLock { connections } }
	var requestLog: [String] { lock.withLock { requests } }

	func stop() {
		listener.cancel()
		lock.withLock { open }.forEach { $0.cancel() }
	}

	private func accept(_ connection: NWConnection) {
		lock.withLock {
			connections += 1
			open.append(connection)
		}
		connection.start(queue: queue)
		read(connection, Data())
	}

	private func read(_ connection: NWConnection, _ sofar: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
			guard let self else { return }
			var buffer = sofar
			if let data { buffer.append(data) }
			if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
				let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
				let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
				let path = target.split(separator: "?").first.map(String.init) ?? target
				let steps = self.lock.withLock {
					self.requests.append(head)
					return self.script[path] ?? [.send(Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8))]
				}
				self.run(steps[...], on: connection)
			} else if !done, error == nil {
				self.read(connection, buffer)
			}
		}
	}

	private func run(_ steps: ArraySlice<Step>, on connection: NWConnection) {
		guard let step = steps.first else {
			connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
				connection.cancel()
			})
			return
		}
		switch step {
		case .send(let data):
			connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.run(steps.dropFirst(), on: connection) })
		case .wait(let seconds):
			queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.run(steps.dropFirst(), on: connection) }
		case .hang:
			break
		}
	}
}

final class PeerHTTPTests: XCTestCase {
	var server: RawHTTPServer!
	let loopback = PeerHTTP(allowsHost: { $0 == "127.0.0.1" || $0 == "::1" })

	override func setUpWithError() throws { server = try RawHTTPServer() }
	override func tearDown() { server.stop() }

	private func get(_ path: String, client: PeerHTTP? = nil, maxBytes: Int = PeerHTTP.maxBytes, deadline: TimeInterval = 2)
		async -> Data?
	{
		await (client ?? loopback).get(host: "127.0.0.1", port: server.port, target: path, maxBytes: maxBytes, deadline: deadline)
	}

	private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

	func testA200WithContentLengthIsItsBodyAndTheRequestIsOneClosingGet() async {
		server.on("/v1/link/peer", raw: "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
		let body = await get("/v1/link/peer?from=dev_x&nonce=abc-_&ts=1&sig=s")
		XCTAssertEqual(text(body), #"{"ok":true}"#)
		let request = try? XCTUnwrap(server.requestLog.first)
		XCTAssertEqual(server.requestLog.count, 1)
		XCTAssertTrue(request?.hasPrefix("GET /v1/link/peer?from=dev_x&nonce=abc-_&ts=1&sig=s HTTP/1.1\r\n") == true)
		XCTAssertTrue(request?.contains("\r\nHost: 127.0.0.1:\(server.port)") == true)
		XCTAssertTrue(request?.contains("\r\nConnection: close") == true)
		XCTAssertFalse(request?.lowercased().contains("accept-encoding") == true)
	}

	func testBytesPastContentLengthAreIgnored() async {
		server.on("/ok", raw: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA")
		let body = await get("/ok")
		XCTAssertEqual(text(body), "hello")
	}

	func testABodyWithoutContentLengthEndsWhenTheConnectionCloses() async {
		server.on("/close", [.send(Data("HTTP/1.0 200 OK\r\n\r\nhel".utf8)), .wait(0.1), .send(Data("lo".utf8))])
		let body = await get("/close")
		XCTAssertEqual(text(body), "hello")
	}

	func testAnEmpty200IsAnEmptyBody() async {
		server.on("/empty", raw: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
		let body = await get("/empty")
		XCTAssertEqual(body, Data())
	}

	func testABodyOverTheCapIsNothing() async {
		let big = String(repeating: "x", count: PeerHTTP.maxBytes + 1)
		server.on("/streamed", [.send(Data("HTTP/1.0 200 OK\r\n\r\n".utf8)), .send(Data(big.utf8))])
		server.on("/declared", raw: "HTTP/1.0 200 OK\r\nContent-Length: \(PeerHTTP.maxBytes + 1)\r\n\r\n")
		server.on("/small-cap", raw: "HTTP/1.0 200 OK\r\nContent-Length: 2000\r\n\r\n" + String(repeating: "y", count: 2000))
		let streamed = await get("/streamed")
		XCTAssertNil(streamed)
		let started = Date()
		// The declared length alone refuses it, without waiting for bytes that never come.
		let declared = await get("/declared", deadline: 3)
		XCTAssertNil(declared)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
		let capped = await get("/small-cap", maxBytes: 1024)
		XCTAssertNil(capped)
		let exactly = String(repeating: "z", count: PeerHTTP.maxBytes)
		server.on("/at-cap", [.send(Data("HTTP/1.0 200 OK\r\n\r\n".utf8)), .send(Data(exactly.utf8))])
		let atCap = await get("/at-cap")
		XCTAssertEqual(atCap?.count, PeerHTTP.maxBytes)
	}

	func testARedirectIsNotFollowed() async {
		server.on("/ok", raw: "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello")
		for status in ["301 Moved Permanently", "302 Found", "307 Temporary Redirect", "308 Permanent Redirect"] {
			server.on("/redirect", raw: "HTTP/1.1 \(status)\r\nLocation: http://127.0.0.1:\(server.port)/ok\r\nContent-Length: 0\r\n\r\n")
			let before = server.requestLog.count
			let body = await get("/redirect")
			XCTAssertNil(body, status)
			try? await Task.sleep(nanoseconds: 100_000_000)
			XCTAssertEqual(server.requestLog.count, before + 1, "followed \(status)")
		}
	}

	func testAnyOtherStatusIsNothing() async {
		for status in ["404 Not Found", "500 Internal Server Error", "204 No Content", "100 Continue", "201 Created"] {
			server.on("/status", raw: "HTTP/1.1 \(status)\r\nContent-Length: 5\r\n\r\nhello")
			let body = await get("/status")
			XCTAssertNil(body, status)
		}
	}

	func testMalformedResponsesAreNothing() async {
		let cases: [String: String] = [
			"garbage": "hello world\r\n\r\n",
			"http2": "HTTP/2 200 OK\r\nContent-Length: 2\r\n\r\nhi",
			"http09": "HTTP/0.9 200 OK\r\nContent-Length: 2\r\n\r\nhi",
			"short-status": "HTTP/1.1 20 OK\r\nContent-Length: 2\r\n\r\nhi",
			"letter-status": "HTTP/1.1 2x0 OK\r\nContent-Length: 2\r\n\r\nhi",
			"no-colon": "HTTP/1.1 200 OK\r\nContent-Length 2\r\n\r\nhi",
			"obs-fold": "HTTP/1.1 200 OK\r\nX-A: b\r\n c\r\nContent-Length: 2\r\n\r\nhi",
			"space-before-colon": "HTTP/1.1 200 OK\r\nContent-Length : 2\r\n\r\nhi",
			"chunked": "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n",
			"te-and-cl": "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\nhi",
			"two-lengths": "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nhi!",
			"negative-length": "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nhi",
			"hex-length": "HTTP/1.1 200 OK\r\nContent-Length: 0x2\r\n\r\nhi",
			"gzip": "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nhi",
			"bare-lf": "HTTP/1.1 200 OK\nContent-Length: 2\n\nhi",
			"nul-in-head": "HTTP/1.1 200 OK\r\nX-A: \u{0}\r\nContent-Length: 2\r\n\r\nhi",
			"truncated-body": "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhi",
			"head-only-then-close": "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n",
			"empty": "",
		]
		for (name, raw) in cases {
			server.on("/m", raw: raw)
			let body = await get("/m")
			XCTAssertNil(body, name)
		}
		// A head that never ends is refused once it passes the cap, not read forever.
		let endless = "HTTP/1.1 200 OK\r\n" + String(repeating: "X-Pad: \(String(repeating: "p", count: 100))\r\n", count: 200)
		server.on("/m", [.send(Data(endless.utf8)), .hang])
		let started = Date()
		let body = await get("/m", deadline: 3)
		XCTAssertNil(body)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
	}

	func testASlowPeerHitsTheOneDeadline() async {
		server.on("/silent", [.hang])
		server.on("/trickle", [
			.send(Data("HTTP/1.0 200 OK\r\nContent-Length: 50\r\n\r\n".utf8)), .wait(0.4), .send(Data("aaaaa".utf8)), .wait(0.4),
			.send(Data("bbbbb".utf8)), .wait(0.4), .send(Data("ccccc".utf8)), .wait(0.4), .send(Data("ddddd".utf8)), .hang,
		])
		for path in ["/silent", "/trickle"] {
			let started = Date()
			let body = await get(path, deadline: 1)
			XCTAssertNil(body, path)
			let took = Date().timeIntervalSince(started)
			XCTAssertGreaterThan(took, 0.9, path)
			XCTAssertLessThan(took, 1.6, path)
		}
		XCTAssertEqual(PeerHTTP.deadline, 5)
		XCTAssertEqual(PeerHTTP.maxBytes, 256 * 1024)
	}

	func testOnlyTailscaleAddressesAreDialled() async {
		let strict = PeerHTTP()
		server.on("/ok", raw: "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello")
		let refused = await strict.get(host: "127.0.0.1", port: server.port, target: "/ok")
		XCTAssertNil(refused)
		let byURL = await strict.get(URL(string: "http://127.0.0.1:\(server.port)/ok")!)
		XCTAssertNil(byURL)
		let byName = await strict.get(host: "localhost", port: server.port, target: "/ok")
		XCTAssertNil(byName)
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(server.connectionCount, 0, "a refused address must not be connected to at all")

		let tailnet = [
			"100.64.0.1", "100.127.255.255", "100.100.100.1", "100.100.100.2", "fd7a:115c:a1e0::1",
			"fd7a:115c:a1e0:1:2:3:4:5", "FD7A:115C:A1E0::2",
		]
		for host in tailnet { XCTAssertTrue(PeerHTTP.isTailnetAddress(host), host) }
		let others = [
			"127.0.0.1", "10.0.0.1", "10.0.0.94", "100.63.255.255", "100.128.0.1", "1.1.1.1", "0.0.0.0",
			"::1", "fd7a:115c:a1e1::1", "fd7b:115c:a1e0::1", "::ffff:100.64.0.1", "fd7a:115c:a1e0::1%utun4",
			"100.64.1", "100.64.0.1.5", "0100.64.0.1", "100.064.0.1", "100.64.0.256", "100.64.0.1 ", " 100.64.0.1",
			"100.64.0.1:7787", "mac-b", "mac-b.example.ts.net", "", "100.64.0.x", "١٠٠.64.0.1",
		]
		for host in others { XCTAssertFalse(PeerHTTP.isTailnetAddress(host), host) }
		// Production wiring: the real tailnet identity only allows those.
		XCTAssertFalse(TailscaleProbePolicy().isProbeAddress("127.0.0.1"))
		XCTAssertTrue(TailscaleProbePolicy().isProbeAddress("100.100.100.2"))
	}

	func testAnUnsafeTargetOrURLIsRefusedBeforeConnecting() async {
		let any = PeerHTTP(allowsHost: { _ in true })
		for target in ["/ok HTTP/1.1\r\nX: y", "/ok\r\n", "ok", "/o k", "/ok\u{7f}", ""] {
			let body = await any.get(host: "127.0.0.1", port: server.port, target: target)
			XCTAssertNil(body, target.debugDescription)
		}
		for url in ["https://127.0.0.1:\(server.port)/ok", "http://user:pw@127.0.0.1:\(server.port)/ok", "ftp://127.0.0.1/ok"] {
			let body = await any.get(URL(string: url)!)
			XCTAssertNil(body, url)
		}
		for port in [0, -1, 70000] {
			let body = await any.get(host: "127.0.0.1", port: port, target: "/ok")
			XCTAssertNil(body)
		}
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(server.connectionCount, 0)
	}

	func testIPv6LiteralsWork() async {
		server.on("/ok", raw: "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello")
		let plain = await loopback.get(host: "::1", port: server.port, target: "/ok")
		XCTAssertEqual(text(plain), "hello")
		let bracketed = await loopback.get(URL(string: "http://[::1]:\(server.port)/ok")!)
		XCTAssertEqual(text(bracketed), "hello")
		XCTAssertTrue(server.requestLog.last?.contains("\r\nHost: [::1]:\(server.port)") == true)
	}

	func testInvalidateAndTaskCancellationStopWhatIsInFlight() async {
		server.on("/silent", [.hang])
		let client = loopback
		let port = server.port
		var started = Date()
		let waiting = Task { await client.get(host: "127.0.0.1", port: port, target: "/silent", deadline: 5) }
		try? await Task.sleep(nanoseconds: 300_000_000)
		client.invalidate()
		let invalidated = await waiting.value
		XCTAssertNil(invalidated)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

		started = Date()
		let cancelled = Task { await client.get(host: "127.0.0.1", port: port, target: "/silent", deadline: 5) }
		try? await Task.sleep(nanoseconds: 300_000_000)
		cancelled.cancel()
		let afterCancel = await cancelled.value
		XCTAssertNil(afterCancel)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

		// Cancelled before it ever started.
		let early = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await client.get(host: "127.0.0.1", port: port, target: "/silent", deadline: 5)
		}
		started = Date()
		let earlyResult = await early.value
		XCTAssertNil(earlyResult)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

		// The client still works after an invalidate.
		server.on("/ok", raw: "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello")
		let again = await client.get(host: "127.0.0.1", port: port, target: "/ok")
		XCTAssertEqual(text(again), "hello")
	}

	func testARefusedPortFailsFastAndParallelGetsAreIndependent() async throws {
		let closed = try RawHTTPServer()
		let closedPort = closed.port
		closed.stop()
		try? await Task.sleep(nanoseconds: 200_000_000)
		let started = Date()
		let refused = await loopback.get(host: "127.0.0.1", port: closedPort, target: "/ok", deadline: 3)
		XCTAssertNil(refused)
		XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

		server.on("/ok", raw: "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello")
		server.on("/silent", [.hang])
		let client = loopback
		let port = server.port
		let results = await withTaskGroup(of: (String, Data?).self) { group in
			for index in 0..<12 {
				let path = index % 3 == 0 ? "/silent" : "/ok"
				group.addTask { (path, await client.get(host: "127.0.0.1", port: port, target: path, deadline: 1)) }
			}
			var out: [(String, Data?)] = []
			for await result in group { out.append(result) }
			return out
		}
		XCTAssertEqual(results.count, 12)
		for (path, body) in results {
			if path == "/ok" { XCTAssertEqual(text(body), "hello") } else { XCTAssertNil(body) }
		}
	}
}

/// Run from launchd (no TERM), Tailscale.app's binary starts its GUI instead of answering.
final class TailscaleCLIEnvironmentTests: XCTestCase {
	func testTheCLIAlwaysGetsATerm() throws {
		let saved = ProcessInfo.processInfo.environment["TERM"]
		unsetenv("TERM")
		defer { if let saved { setenv("TERM", saved, 1) } }
		let unset = try XCTUnwrap(TailscaleCLIIdentity.run("/usr/bin/printenv", ["TERM"]))
		XCTAssertEqual(String(decoding: unset, as: UTF8.self), "dumb\n")
		setenv("TERM", "xterm-256color", 1)
		let kept = try XCTUnwrap(TailscaleCLIIdentity.run("/usr/bin/printenv", ["TERM"]))
		XCTAssertEqual(String(decoding: kept, as: UTF8.self), "xterm-256color\n")
	}
}

/// The production `TailnetIdentity` default, without the Tailscale CLI.
private struct TailscaleProbePolicy: TailnetIdentity {
	func ownerMacs() async -> [TailnetPeer] { [] }
	func whois(_ address: String) -> TailnetNode? { nil }
	var selfNodeID: String? { nil }
}
