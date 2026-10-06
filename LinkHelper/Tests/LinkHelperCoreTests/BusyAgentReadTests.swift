import XCTest

@testable import LinkHelperCore

/// herdr 0.9.1 refuses a `recent` read longer than the screen while an alternate-screen agent
/// works (`agent_not_idle`). The phone asks for 200 recent lines, so the output of every
/// working Claude Code or Codex agent used to come back as a 502.
final class BusyAgentReadTests: XCTestCase {
	/// A herdr socket with one agent: idle reads answer any source; while `working`, a recent
	/// read over `screenRows` lines gets herdr's real refusal.
	final class BusyHerdr: @unchecked Sendable {
		let path: String
		let screenRows = 50
		private let listener: UnixListener
		private let lock = NSLock()
		private var working = true
		private(set) var reads: [[String: Any]] = []

		init() throws {
			path = FileManager.default.temporaryDirectory.appendingPathComponent(
				"busy-\(UUID().uuidString.prefix(8)).sock"
			).path
			listener = UnixListener(path: path)
			try listener.start(name: "busy-herdr") { [weak self] connection in self?.serve(connection) }
		}

		func setWorking(_ value: Bool) {
			lock.lock()
			working = value
			lock.unlock()
		}

		var readCount: Int {
			lock.lock()
			defer { lock.unlock() }
			return reads.count
		}

		func stop() { listener.stop() }

		private func serve(_ connection: UnixConnection) {
			defer { connection.close() }
			guard case .line(let line) = try? connection.readLine(timeout: 5),
				let request = WireJSON.decodeObject(line), let id = request["id"] as? String
			else { return }
			let params = request["params"] as? [String: Any] ?? [:]
			lock.lock()
			reads.append(params)
			let busy = working
			lock.unlock()
			let source = params["source"] as? String ?? "recent"
			let lines = params["lines"] as? Int ?? 50
			let target = params["target"] as? String ?? ""
			if busy, source != "visible", lines > screenRows {
				try? connection.sendLine([
					"id": id,
					"error": [
						"code": "agent_not_idle",
						"message":
							"cannot read \(lines) lines while \(target) is working: its alternate-screen history can only be captured by scrolling while idle. Wait and retry, or use --source visible",
					],
				])
				return
			}
			let count = source == "visible" ? min(lines, screenRows) : lines
			let text = (1...count).map { "\(source) line \($0)" }.joined(separator: "\n")
			try? connection.sendLine([
				"id": id,
				"result": [
					"type": "pane_read",
					"read": [
						"pane_id": target, "source": source, "text": text, "revision": 7,
						"truncated": source != "visible",
					],
				],
			])
		}
	}

	var herdr: BusyHerdr!

	override func setUpWithError() throws {
		herdr = try BusyHerdr()
	}

	override func tearDown() {
		herdr.stop()
	}

	func testAWorkingAgentsLongReadFallsBackToItsVisibleScreen() throws {
		let client = HerdrClient(socketPath: herdr.path)
		let answer = try client.read("w1:p1", source: "recent", lines: 200)
		XCTAssertEqual(answer["source"] as? String, "visible")
		XCTAssertEqual(answer["truncated"] as? Bool, true)
		let text = try XCTUnwrap(answer["text"] as? String)
		XCTAssertEqual(text.split(separator: "\n").count, herdr.screenRows)
		XCTAssertEqual(herdr.reads.map { $0["source"] as? String }, ["recent", "visible"])
		XCTAssertEqual(herdr.reads.last?["lines"] as? Int, 200)
	}

	func testAnIdleAgentGetsItsRecentHistoryInOneRead() throws {
		herdr.setWorking(false)
		let answer = try HerdrClient(socketPath: herdr.path).read("w1:p1", source: "recent", lines: 200)
		XCTAssertEqual(answer["source"] as? String, "recent")
		XCTAssertEqual((answer["text"] as? String)?.split(separator: "\n").count, 200)
		XCTAssertEqual(herdr.readCount, 1)
	}

	func testAShortRecentReadOfAWorkingAgentIsNotRedirected() throws {
		let answer = try HerdrClient(socketPath: herdr.path).read("w1:p1", source: "recent", lines: 40)
		XCTAssertEqual(answer["source"] as? String, "recent")
		XCTAssertEqual(herdr.readCount, 1)
	}

	func testOtherHerdrErrorsStillSurface() {
		XCTAssertFalse(HerdrClient.isBusyRead(HerdrClient.mapError("invalid_params", "bad source")))
		XCTAssertTrue(HerdrClient.isBusyRead(HerdrClient.mapError("agent_not_idle", "cannot read 200 lines")))
	}

	/// End to end: `GET /v1/agents/{id}/output` for a working agent is a 200 with its screen.
	func testTheOutputRouteAnswersForAWorkingAgent() async throws {
		let daemon = try TestDaemon(herdrSocket: herdr.path)
		defer { daemon.stop() }
		let phone = try await daemon.pairedPhone()
		let response = try await phone.call("GET", "/v1/agents/w1:p1/output?source=recent&lines=200")
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["source"] as? String, "visible")
		XCTAssertEqual(response.json["truncated"] as? Bool, true)
	}
}
