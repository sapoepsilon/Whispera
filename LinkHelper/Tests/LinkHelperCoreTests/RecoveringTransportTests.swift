import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A request that times out on the pooled connection gets the next one a new session, so a
/// dead HTTP/2 connection to the account backend costs one failure instead of minutes of them.
final class RecoveringTransportTests: XCTestCase {
	/// Answers each request with the next scripted outcome for its `X-Stub` key.
	final class StubProtocol: URLProtocol {
		enum Outcome {
			case status(Int)
			case fail(URLError.Code)
		}

		private static let lock = NSLock()
		private static var scripts: [String: [Outcome]] = [:]

		static func script(_ key: String, _ outcomes: [Outcome]) {
			lock.lock()
			scripts[key] = outcomes
			lock.unlock()
		}

		private static func next(_ key: String) -> Outcome {
			lock.lock()
			defer { lock.unlock() }
			guard var queue = scripts[key], !queue.isEmpty else { return .status(200) }
			let outcome = queue.removeFirst()
			scripts[key] = queue
			return outcome
		}

		override class func canInit(with request: URLRequest) -> Bool { true }
		override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

		override func startLoading() {
			switch Self.next(request.value(forHTTPHeaderField: "X-Stub") ?? "") {
			case .status(let code):
				let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/2", headerFields: nil)!
				client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
				client?.urlProtocol(self, didLoad: Data("{}".utf8))
				client?.urlProtocolDidFinishLoading(self)
			case .fail(let code):
				client?.urlProtocol(self, didFailWithError: URLError(code))
			}
		}

		override func stopLoading() {}
	}

	final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [String] = []
		func add(_ value: String) {
			lock.lock()
			values.append(value)
			lock.unlock()
		}
		var all: [String] {
			lock.lock()
			defer { lock.unlock() }
			return values
		}
	}

	private var key = ""
	private let made = Counter()
	private let resets = Counter()

	override func setUp() {
		key = UUID().uuidString
	}

	private func transport() -> RecoveringURLSessionTransport {
		let made = self.made
		let resets = self.resets
		return RecoveringURLSessionTransport(
			makeSession: {
				made.add("session")
				let config = URLSessionConfiguration.ephemeral
				config.protocolClasses = [StubProtocol.self]
				return URLSession(configuration: config)
			},
			onRecycle: { resets.add("\($0.rawValue)") })
	}

	private func request() -> URLRequest {
		var request = URLRequest(url: URL(string: "https://relay.invalid/v1/relay/messages?wait=25")!)
		request.setValue(key, forHTTPHeaderField: "X-Stub")
		return request
	}

	func testTimeoutReplacesTheSessionAndTheNextRequestSucceeds() async throws {
		StubProtocol.script(key, [.fail(.timedOut), .status(200)])
		let transport = transport()
		let first = transport.session
		do {
			_ = try await transport.data(for: request())
			XCTFail("expected a timeout")
		} catch let error as URLError {
			XCTAssertEqual(error.code, .timedOut)
		}
		XCTAssertFalse(transport.session === first)
		XCTAssertEqual(transport.recycleCount, 1)
		XCTAssertEqual(resets.all, ["\(URLError.Code.timedOut.rawValue)"])
		let (_, response) = try await transport.data(for: request())
		XCTAssertEqual(response.statusCode, 200)
		XCTAssertEqual(made.all.count, 2)
	}

	func testLostConnectionReplacesTheSession() async {
		StubProtocol.script(key, [.fail(.networkConnectionLost)])
		let transport = transport()
		_ = try? await transport.data(for: request())
		XCTAssertEqual(transport.recycleCount, 1)
	}

	func testOtherOutcomesKeepTheSession() async throws {
		StubProtocol.script(key, [.status(503), .fail(.cannotConnectToHost), .fail(.cancelled), .fail(.notConnectedToInternet)])
		let transport = transport()
		let first = transport.session
		let (_, response) = try await transport.data(for: request())
		XCTAssertEqual(response.statusCode, 503)
		for _ in 0..<3 { _ = try? await transport.data(for: request()) }
		XCTAssertTrue(transport.session === first)
		XCTAssertEqual(transport.recycleCount, 0)
		XCTAssertEqual(made.all.count, 1)
	}

	func testConcurrentTimeoutsOnOneSessionReplaceItOnce() async {
		StubProtocol.script(key, Array(repeating: .fail(.timedOut), count: 4))
		let transport = transport()
		let request = request()
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<4 {
				group.addTask { _ = try? await transport.data(for: request) }
			}
		}
		XCTAssertEqual(transport.recycleCount, 1)
		XCTAssertEqual(made.all.count, 2)
	}

	func testStreamTimeoutReplacesTheSession() async {
		StubProtocol.script(key, [.fail(.timedOut)])
		let transport = transport()
		_ = try? await transport.stream(for: request())
		XCTAssertEqual(transport.recycleCount, 1)
	}

	/// The relay client still reports a poll timeout as `timed_out`; only the session changes.
	func testRelayClientStillReportsTimedOut() async throws {
		key = ""
		StubProtocol.script(key, [.fail(.timedOut)])
		let transport = transport()
		do {
			_ = try await RelayClient.health(baseURL: URL(string: "https://relay.invalid")!, transport: transport)
			XCTFail("expected a timeout")
		} catch let error as LinkError {
			XCTAssertEqual(error.code, "timed_out")
		}
		XCTAssertEqual(transport.recycleCount, 1)
	}
}
