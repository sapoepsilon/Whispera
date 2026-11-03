import Foundation
import XCTest

@testable import LinkHelperCore

final class ConnectionLimiterTests: XCTestCase {
	func testEachPeerIsCappedOnItsOwn() {
		let limiter = ConnectionLimiter(perPeer: 3, total: 100)
		for _ in 0..<3 { XCTAssertTrue(limiter.acquire("10.0.0.2")) }
		XCTAssertFalse(limiter.acquire("10.0.0.2"))
		XCTAssertTrue(limiter.acquire("10.0.0.3"))
		XCTAssertEqual(limiter.openConnections(from: "10.0.0.2"), 3)
		XCTAssertEqual(limiter.openConnections, 4)
		limiter.release("10.0.0.2")
		XCTAssertTrue(limiter.acquire("10.0.0.2"))
		XCTAssertFalse(limiter.acquire("10.0.0.2"))
	}

	func testTheTotalCapsAllPeersTogether() {
		let limiter = ConnectionLimiter(perPeer: 2, total: 5)
		for peer in ["a", "a", "b", "b", "c"] { XCTAssertTrue(limiter.acquire(peer)) }
		XCTAssertFalse(limiter.acquire("c"))
		XCTAssertFalse(limiter.acquire("d"))
		limiter.release("a")
		XCTAssertTrue(limiter.acquire("d"))
		XCTAssertFalse(limiter.acquire("e"))
	}

	func testReleaseGivesTheSlotBackOnceAndIgnoresStrays() {
		let limiter = ConnectionLimiter(perPeer: 1, total: 1)
		limiter.release("nobody")
		XCTAssertEqual(limiter.openConnections, 0)
		let slot = limiter.slot(for: "p")
		XCTAssertNotNil(slot)
		XCTAssertNil(limiter.slot(for: "p"))
		slot?.release()
		slot?.release()
		XCTAssertEqual(limiter.openConnections, 0)
		XCTAssertEqual(limiter.openConnections(from: "p"), 0)
		XCTAssertNotNil(limiter.slot(for: "p"))
		// A double release of one slot must not free a second one's.
		XCTAssertEqual(limiter.openConnections, 1)
	}

	func testConcurrentAcquiresNeverExceedTheCap() {
		let limiter = ConnectionLimiter(perPeer: 16, total: 128)
		let granted = Counter()
		DispatchQueue.concurrentPerform(iterations: 400) { index in
			if limiter.acquire("peer\(index % 4)") { granted.add() }
		}
		XCTAssertEqual(granted.value, 64)
		XCTAssertEqual(limiter.openConnections, 64)
	}

	private final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0
		func add() {
			lock.lock()
			count += 1
			lock.unlock()
		}
		var value: Int {
			lock.lock()
			defer { lock.unlock() }
			return count
		}
	}

	// MARK: Over a real listener

	/// Answers each request only once `gate` opens, so its connections stay open meanwhile.
	private final class HoldingServer {
		let server: HTTPServer
		let port: Int
		let gate = DispatchSemaphore(value: 0)
		private let lock = NSLock()
		private var served = 0
		private var started = 0

		init(perPeer: Int, total: Int) throws {
			let box = Box()
			server = HTTPServer(
				host: "127.0.0.1", port: 0, advertisement: nil,
				connections: ConnectionLimiter(perPeer: perPeer, total: total)
			) { box.handle?($0) }
			port = try server.start()
			box.handle = { [weak self] exchange in
				guard let self else { return }
				self.lock.lock()
				self.started += 1
				self.lock.unlock()
				self.gate.wait()
				exchange.respond(200, body: Data(#"{"ok":true}"#.utf8))
				self.lock.lock()
				self.served += 1
				self.lock.unlock()
			}
		}

		var handlersStarted: Int {
			lock.lock()
			defer { lock.unlock() }
			return started
		}

		private final class Box: @unchecked Sendable { var handle: ((HTTPExchange) -> Void)? }
	}

	private func request(_ fd: Int32) {
		let head = "GET /v1/x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
		_ = Data(head.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
	}

	private func readAll(_ fd: Int32) -> String {
		var out = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = recv(fd, &buffer, buffer.count, 0)
			guard count > 0 else { break }
			out.append(contentsOf: buffer[0..<count])
		}
		return String(decoding: out, as: UTF8.self)
	}

	private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return true }
			Thread.sleep(forTimeInterval: 0.01)
		}
		return condition()
	}

	func testTheSeventeenthConnectionFromOnePeerGetsA503WithoutAThread() throws {
		let holding = try HoldingServer(perPeer: 16, total: 128)
		defer { holding.server.stop() }
		var held: [Int32] = []
		defer { held.forEach { Darwin.close($0) } }
		for _ in 0..<16 {
			let fd = try ResponseSignatureTests.openSocket(port: holding.port)
			request(fd)
			held.append(fd)
		}
		XCTAssertTrue(waitUntil { holding.handlersStarted == 16 })
		XCTAssertEqual(holding.server.connections.openConnections(from: "127.0.0.1"), 16)

		let extra = try ResponseSignatureTests.openSocket(port: holding.port)
		defer { Darwin.close(extra) }
		request(extra)
		XCTAssertTrue(readAll(extra).hasPrefix("HTTP/1.0 503 "))
		XCTAssertEqual(holding.handlersStarted, 16)

		// Answering the held requests gives every slot back, and the next connection is served.
		for _ in 0..<16 { holding.gate.signal() }
		for fd in held { XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.0 200 ")) }
		XCTAssertTrue(waitUntil { holding.server.connections.openConnections == 0 })
		let next = try ResponseSignatureTests.openSocket(port: holding.port)
		defer { Darwin.close(next) }
		request(next)
		holding.gate.signal()
		XCTAssertTrue(readAll(next).hasPrefix("HTTP/1.0 200 "))
		XCTAssertTrue(waitUntil { holding.server.connections.openConnections == 0 })
	}

	func testAConnectionClosedBeforeItsRequestGivesItsSlotBack() throws {
		let holding = try HoldingServer(perPeer: 2, total: 2)
		defer { holding.server.stop() }
		for _ in 0..<5 {
			let fd = try ResponseSignatureTests.openSocket(port: holding.port)
			Darwin.close(fd)
		}
		XCTAssertTrue(waitUntil { holding.server.connections.openConnections == 0 })
		XCTAssertEqual(holding.handlersStarted, 0)
	}

	func testARefusedPeerGivesItsSlotBackWithoutAThread() throws {
		let holding = try HoldingServer(perPeer: 1, total: 1)
		defer { holding.server.stop() }
		let refused = RefusalBox()
		holding.server.admit = { _, _, _ in false }
		holding.server.onRefused = { refused.add($0) }
		for _ in 0..<3 {
			let fd = try ResponseSignatureTests.openSocket(port: holding.port)
			request(fd)
			XCTAssertEqual(readAll(fd), "")
			Darwin.close(fd)
		}
		XCTAssertTrue(waitUntil { refused.count == 3 })
		XCTAssertTrue(waitUntil { holding.server.connections.openConnections == 0 })
		XCTAssertEqual(holding.handlersStarted, 0)
	}

	private final class RefusalBox: @unchecked Sendable {
		private let lock = NSLock()
		private var peers: [String] = []
		func add(_ peer: String) {
			lock.lock()
			peers.append(peer)
			lock.unlock()
		}
		var count: Int {
			lock.lock()
			defer { lock.unlock() }
			return peers.count
		}
	}
}
