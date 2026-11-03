import Foundation
import class Network.NWProtocolTCP
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A pane that echoes input and records what the session asked of it.
final class FakeTerminalBackend: TerminalBackend, @unchecked Sendable {
	let provider = "herdr"
	private let lock = NSLock()
	private var sink: (@Sendable (TerminalBackendEvent) -> Void)?
	private var size: TerminalSize
	private(set) var written: [Data] = []
	private(set) var resized: [TerminalSize] = []
	private(set) var unfitTo: TerminalSize?
	private(set) var repaints = 0
	private(set) var stopped = false
	private(set) var stopRestore: TerminalSize?

	init(size: TerminalSize = TerminalSize(cols: 120, rows: 40)) { self.size = size }

	var paneSize: TerminalSize? {
		lock.lock()
		defer { lock.unlock() }
		return size
	}

	private func send(_ event: TerminalBackendEvent) {
		lock.lock()
		let sink = self.sink
		lock.unlock()
		sink?(event)
	}

	func start(_ sink: @escaping @Sendable (TerminalBackendEvent) -> Void) throws {
		lock.lock()
		self.sink = sink
		lock.unlock()
		send(.output(Data("\u{1B}[2Jscreen".utf8), full: true, size: paneSize!))
	}

	func emit(_ text: String) { send(.output(Data(text.utf8), full: false, size: paneSize!)) }

	func emitAppScroll(_ app: Bool) { send(.appScroll(app)) }

	func write(_ data: Data) throws {
		lock.lock()
		written.append(data)
		lock.unlock()
		send(.output(data, full: false, size: paneSize!))
	}

	func resizePane(_ size: TerminalSize) throws {
		lock.lock()
		resized.append(size)
		self.size = size
		lock.unlock()
		send(.size(size))
	}

	func unfit(restore original: TerminalSize) throws {
		lock.lock()
		unfitTo = original
		size = original
		lock.unlock()
		send(.size(original))
	}

	func repaint() throws {
		lock.lock()
		repaints += 1
		lock.unlock()
		send(.output(Data("\u{1B}[2Jrepaint".utf8), full: true, size: paneSize!))
	}

	func stop(restore original: TerminalSize?) {
		lock.lock()
		stopped = true
		stopRestore = original
		lock.unlock()
	}

	var scrollsApps = true
	private(set) var scrolled: [Int] = []

	func scrollApp(_ notches: Int) throws -> Bool {
		lock.lock()
		scrolled.append(notches)
		lock.unlock()
		return true
	}
}

final class TerminalTestClock: @unchecked Sendable {
	var now: Double = 1_000_000
}

/// Decoded server frames, for assertions.
enum Seen: Equatable {
	case hello(resumed: Bool, cols: Int, rows: Int)
	case output(UInt64, String)
	case reset
	case size(Int, Int)
	case ack(UInt32)
	case exit(String)

	init(_ frame: Data) {
		let bytes = [UInt8](frame)
		let json = WireJSON.decodeObject(Data(bytes.dropFirst())) ?? [:]
		switch bytes[0] {
		case TerminalFrame.hello:
			self = .hello(resumed: json["resumed"] as? Bool ?? false, cols: json["cols"] as? Int ?? 0, rows: json["rows"] as? Int ?? 0)
		case TerminalFrame.output:
			let seq = bytes[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
			self = .output(seq, String(decoding: bytes[9...], as: UTF8.self))
		case TerminalFrame.reset: self = .reset
		case TerminalFrame.size: self = .size(json["cols"] as? Int ?? 0, json["rows"] as? Int ?? 0)
		case TerminalFrame.ack:
			self = .ack(bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
		default: self = .exit(json["reason"] as? String ?? "?")
		}
	}
}

final class TerminalBetaTests: XCTestCase {
	// MARK: WebSocket codec

	func testListenerTurnsNagleOff() throws {
		let options = try XCTUnwrap(HTTPServer.parameters().defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
		XCTAssertTrue(options.noDelay, "terminal frames go out at once, not behind the peer's delayed ACK")
	}

	func testAcceptKeyMatchesTheRFCExample() {
		XCTAssertEqual(WebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
		XCTAssertTrue(WebSocket.isValidKey("dGhlIHNhbXBsZSBub25jZQ=="))
		XCTAssertFalse(WebSocket.isValidKey("c2hvcnQ="))
	}

	func testMaskedFramesRoundTripAtTheLengthBoundaries() throws {
		let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
		for (length, headerLength, lengthByte) in [(0, 6, 0), (125, 6, 125), (126, 8, 126), (65535, 8, 126), (65536, 14, 127)] {
			let payload = Data((0..<length).map { UInt8($0 & 0xFF) })
			let encoded = WebSocket.encode(.binary, payload, mask: mask)
			XCTAssertEqual(encoded.count, headerLength + length)
			XCTAssertEqual(encoded[1], 0x80 | UInt8(lengthByte))
			if length > 0 { XCTAssertNotEqual(encoded.suffix(length), payload, "payload is masked on the wire") }
			let (frame, used) = try XCTUnwrap(try WebSocket.decodeFrame(encoded + Data([0x81]), requireMask: true))
			XCTAssertEqual(used, encoded.count)
			XCTAssertEqual(frame, WebSocket.Frame(fin: true, opcode: .binary, payload: payload))
			XCTAssertNil(try WebSocket.decodeFrame(encoded.prefix(encoded.count - 1), requireMask: true))
		}
	}

	func testServerFramesAreUnmaskedAndClientFramesMustBeMasked() throws {
		let server = WebSocket.encode(.binary, Data("hi".utf8))
		XCTAssertEqual([UInt8](server), [0x82, 0x02, 0x68, 0x69])
		XCTAssertThrowsError(try WebSocket.decodeFrame(server, requireMask: true))
		XCTAssertNotNil(try WebSocket.decodeFrame(server, requireMask: false))
	}

	func testFragmentsReassembleAroundAPingAndLimitsHold() throws {
		var assembler = WebSocket.Assembler(maxMessage: 10)
		XCTAssertNil(try assembler.push(.init(fin: false, opcode: .binary, payload: Data("abc".utf8))))
		XCTAssertEqual(try assembler.push(.init(fin: true, opcode: .ping, payload: Data("p".utf8))), .ping(Data("p".utf8)))
		XCTAssertNil(try assembler.push(.init(fin: false, opcode: .continuation, payload: Data("def".utf8))))
		XCTAssertEqual(
			try assembler.push(.init(fin: true, opcode: .continuation, payload: Data("g".utf8))), .binary(Data("abcdefg".utf8)))
		XCTAssertThrowsError(try assembler.push(.init(fin: true, opcode: .continuation, payload: Data()))) {
			XCTAssertEqual($0 as? WebSocket.Failure, .protocolError("continuation without a message"))
		}
		XCTAssertNil(try assembler.push(.init(fin: false, opcode: .text, payload: Data("123456".utf8))))
		XCTAssertThrowsError(try assembler.push(.init(fin: true, opcode: .continuation, payload: Data("78901".utf8)))) {
			XCTAssertEqual($0 as? WebSocket.Failure, .tooBig)
		}
		XCTAssertThrowsError(
			try WebSocket.decodeFrame(WebSocket.encode(.binary, Data(count: 2000), mask: [1, 2, 3, 4]), requireMask: true, maxPayload: 1000)
		) { XCTAssertEqual($0 as? WebSocket.Failure, .tooBig) }
		XCTAssertThrowsError(
			try WebSocket.decodeFrame(WebSocket.encode(.ping, Data(count: 126), mask: [1, 2, 3, 4]), requireMask: true))
		XCTAssertThrowsError(
			try WebSocket.decodeFrame(WebSocket.encode(.ping, Data(), fin: false, mask: [1, 2, 3, 4]), requireMask: true))
	}

	func testCloseFramesCarryTheirCode() throws {
		var assembler = WebSocket.Assembler()
		let encoded = WebSocket.encode(.close, WebSocket.closePayload(1001, "bye"), mask: [9, 8, 7, 6])
		let (frame, _) = try XCTUnwrap(try WebSocket.decodeFrame(encoded, requireMask: true))
		XCTAssertEqual(try assembler.push(frame), .close(code: 1001, reason: Data("bye".utf8)))
		XCTAssertEqual(try assembler.push(.init(fin: true, opcode: .close, payload: Data())), .close(code: nil, reason: Data()))
		XCTAssertThrowsError(try assembler.push(.init(fin: true, opcode: .close, payload: Data([3]))))
	}

	// MARK: Terminal frames

	func testFrameEncodings() throws {
		XCTAssertEqual([UInt8](TerminalFrame.encodeOutput(seq: 258, Data("x".utf8))), [2, 0, 0, 0, 0, 0, 0, 1, 2, 0x78])
		XCTAssertEqual([UInt8](TerminalFrame.encodeAck(0x0102_0304)), [5, 1, 2, 3, 4])
		XCTAssertEqual(Seen(TerminalFrame.encodeExit(.rateLimited)), .exit("rate_limited"))
		XCTAssertEqual(Seen(TerminalFrame.encodeSize(TerminalSize(cols: 80, rows: 24))), .size(80, 24))
		let hello = TerminalFrame.encodeHello(
			session: "term_0123456789ab", size: TerminalSize(cols: 120, rows: 40), mode: .mirror, provider: "herdr",
			resumed: false, idleTimeout: 1800)
		let object = try XCTUnwrap(WireJSON.decodeObject(hello.dropFirst()))
		XCTAssertEqual(hello.first, 1)
		XCTAssertEqual(object["session"] as? String, "term_0123456789ab")
		XCTAssertEqual(object["idle_timeout"] as? Int, 1800)
		XCTAssertEqual(object["provider"] as? String, "herdr")
		XCTAssertEqual(object["scroll"] as? Bool, false)
		for frame: TerminalFrame.Client in [
			.input(seq: 7, Data("ls\r".utf8)), .resize(TerminalSize(cols: 500, rows: 2)), .mode(.fit), .mode(.mirror),
			.scroll(3), .scroll(-20),
		] {
			XCTAssertEqual(try TerminalFrame.decodeClient(TerminalFrame.encodeClient(frame)), frame)
		}
		XCTAssertEqual([UInt8](TerminalFrame.encodeClient(.resize(TerminalSize(cols: 300, rows: 50)))), [0x11, 1, 44, 0, 50])
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x11, 0, 1, 0, 50])))
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x10, 0, 0, 0, 1])), "empty input")
		XCTAssertThrowsError(try TerminalFrame.decodeClient(TerminalFrame.encodeClient(.input(seq: 1, Data(count: 16 * 1024 + 1)))))
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x12]) + Data(#"{"mode":"big"}"#.utf8)))
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x7F])))
		XCTAssertEqual([UInt8](TerminalFrame.encodeClient(.scroll(-2))), [0x13, 0xFF, 0xFE])
		XCTAssertEqual(try TerminalFrame.decodeClient(Data([0x13, 0x00, 0x05])), .scroll(5))
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x13, 0x00, 0x00])), "no notches")
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x13, 0x00, 0x15])), "over 20 notches")
		XCTAssertThrowsError(try TerminalFrame.decodeClient(Data([0x13, 0x01])), "truncated")
	}

	/// herdr's `terminal.scroll` moves its view of a pane with scrollback (the Mac's too): only a
	/// pane at the bottom with nothing above, as on the alternate screen, gets it.
	func testHerdrScrollsOnlyAPaneWithoutScrollback() {
		func info(_ max: Any?, _ offset: Any?) -> [String: Any] {
			var scroll: [String: Any] = ["viewport_rows": 40]
			scroll["max_offset_from_bottom"] = max
			scroll["offset_from_bottom"] = offset
			return ["type": "pane_info", "pane": ["pane_id": "w1:p2", "scroll": scroll]]
		}
		XCTAssertTrue(HerdrControlBackend.hasNoScrollback(info(0, 0)))
		XCTAssertFalse(HerdrControlBackend.hasNoScrollback(info(169, 0)), "a shell with history")
		XCTAssertFalse(HerdrControlBackend.hasNoScrollback(info(0, 3)))
		XCTAssertFalse(HerdrControlBackend.hasNoScrollback(info(nil, nil)))
		XCTAssertFalse(HerdrControlBackend.hasNoScrollback(["type": "pane_info", "pane": ["pane_id": "w1:p2"]]))
		XCTAssertFalse(HerdrControlBackend.hasNoScrollback(info("0", 0)))
	}

	func testScrollFramesReachTheBackendAndHelloSaysSo() throws {
		let backend = FakeTerminalBackend()
		let session = PhoneTerminalSession(
			agentID: "w1:p1", device: device(), backend: backend, mode: .mirror,
			phoneSize: TerminalSize(cols: 50, rows: 20), idleTimeout: 1800)
		try session.start(timeout: 1)
		let (generation, _) = session.attach(after: nil)
		guard case .frames(let frames) = session.next(generation, timeout: 0.5), let hello = frames.first?.1 else {
			return XCTFail("hello")
		}
		XCTAssertEqual(WireJSON.decodeObject(hello.dropFirst())?["scroll"] as? Bool, true)
		XCTAssertNil(try session.handle(.scroll(3)))
		XCTAssertNil(try session.handle(.scroll(-1)))
		XCTAssertEqual(backend.scrolled, [3, -1])
		XCTAssertEqual(backend.written, [], "a scroll writes no input bytes")

		backend.emitAppScroll(true)
		backend.emitAppScroll(true)
		backend.emitAppScroll(false)
		guard case .frames(let states) = session.next(generation, timeout: 0.5) else { return XCTFail("scroll state") }
		XCTAssertEqual(
			states.map { [UInt8]($0.1) }, [[0x07] + Array(#"{"app":true}"#.utf8), [0x07] + Array(#"{"app":false}"#.utf8)],
			"changes only")
		session.detach(generation)
		let (again, _) = session.attach(after: 1)
		guard case .frames(let resumed) = session.next(again, timeout: 0.5), let hello2 = resumed.first?.1 else {
			return XCTFail("hello on resume")
		}
		XCTAssertEqual(WireJSON.decodeObject(hello2.dropFirst())?["app_scroll"] as? Bool, false)
	}

	// MARK: Ring and resume

	func testRingReplaysExactlyTheFramesAfterN() throws {
		var ring = TerminalRing()
		for seq in 1...10 {
			ring.append(TerminalFrame.encodeOutput(seq: UInt64(seq), Data("\(seq)".utf8)), outputSeq: UInt64(seq))
			if seq == 5 { ring.append(TerminalFrame.encodeSize(TerminalSize(cols: 90, rows: 30)), outputSeq: nil) }
		}
		let after5 = try XCTUnwrap(ring.frames(after: 5)).map { Seen($0.frame) }
		XCTAssertEqual(after5, [.size(90, 30)] + (6...10).map { .output(UInt64($0), "\($0)") })
		XCTAssertEqual(try XCTUnwrap(ring.frames(after: 6)).map { Seen($0.frame) }, (7...10).map { .output(UInt64($0), "\($0)") })
		XCTAssertEqual(ring.frames(after: 10)?.count, 0)
		XCTAssertNil(ring.frames(after: 11), "a seq from the future")
	}

	func testRingEvictionMakesOldResumesFail() {
		var ring = TerminalRing(maxFrames: 4, maxBytes: 1 << 20)
		for seq in 1...8 { ring.append(TerminalFrame.encodeOutput(seq: UInt64(seq), Data()), outputSeq: UInt64(seq)) }
		XCTAssertNil(ring.frames(after: 3))
		XCTAssertEqual(ring.frames(after: 4)?.count, 4)
		var bytes = TerminalRing(maxFrames: 100, maxBytes: 100)
		for seq in 1...5 { bytes.append(TerminalFrame.encodeOutput(seq: UInt64(seq), Data(count: 40)), outputSeq: UInt64(seq)) }
		XCTAssertLessThanOrEqual(bytes.bytes, 100)
		XCTAssertNil(bytes.frames(after: 1))
		XCTAssertNotNil(bytes.frames(after: 4))
	}

	private func device(_ id: String = "dev_aaaaaaaaaaaaaaaaaaaaaaaa") -> DeviceRecord {
		DeviceRecord(
			deviceID: id, name: "iPhone", link: SoftwareSigningKey().publicKey, approve: SoftwareSigningKey().publicKey,
			sttKeySHA256: "", apns: nil, app: nil, now: 1, approveConfirmed: true, origin: .code)
	}

	private func drain(_ session: PhoneTerminalSession, _ generation: Int) -> [Seen] {
		guard case .frames(let frames) = session.next(generation, timeout: 0.5) else { return [] }
		return frames.map { Seen($0.1) }
	}

	func testSessionResumeReplaysExactlyAndTooOldResumesRepaint() throws {
		let backend = FakeTerminalBackend()
		let session = PhoneTerminalSession(
			agentID: "w1:p1", device: device(), backend: backend, mode: .mirror,
			phoneSize: TerminalSize(cols: 50, rows: 20), idleTimeout: 1800)
		try session.start(timeout: 1)
		let (first, _) = session.attach(after: nil)
		XCTAssertEqual(
			drain(session, first), [.hello(resumed: false, cols: 120, rows: 40), .reset, .output(1, "\u{1B}[2Jscreen")])
		for index in 2...6 { backend.emit("o\(index)") }
		XCTAssertEqual(drain(session, first), (2...6).map { .output(UInt64($0), "o\($0)") })
		session.detach(first)
		backend.emit("o7")
		let (second, resumed) = session.attach(after: 3)
		XCTAssertTrue(resumed)
		XCTAssertEqual(
			drain(session, second),
			[.hello(resumed: true, cols: 120, rows: 40)] + (4...7).map { .output(UInt64($0), "o\($0)") })
		if case .superseded = session.next(first, timeout: 0) {} else { XCTFail("the old stream is superseded") }

		for index in 8...600 { backend.emit("o\(index)") }
		session.detach(second)
		let (third, honoured) = session.attach(after: 5)
		XCTAssertFalse(honoured)
		XCTAssertEqual(backend.repaints, 1)
		XCTAssertEqual(
			drain(session, third), [.hello(resumed: false, cols: 120, rows: 40), .reset, .output(601, "\u{1B}[2Jrepaint")])
	}

	func testHelperShutdownDropsTheStreamWithoutAnExit() throws {
		var config = HelperConfig(paths: .init(config: "/nonexistent", stateDir: "/tmp", log: "/dev/null"))
		config.herdrCLI = ""
		config.tmuxCLI = ""
		let bridge = TerminalBridge(config: config, log: { _, _ in })
		let backend = FakeTerminalBackend()
		bridge.makeBackend = { _ in backend }
		bridge.checkTarget = { _ in }
		let (session, generation) = try bridge.open(
			agentID: "w1:p1", device: device(), size: TerminalSize(cols: 50, rows: 20), mode: .mirror, resume: nil, after: nil)
		_ = drain(session, generation)
		bridge.closeAll()
		XCTAssertTrue(backend.stopped)
		XCTAssertEqual(drain(session, generation), [], "no exit frame: the phone reconnects to the next helper")
		if case .ended = session.next(generation, timeout: 0) {} else { XCTFail("the stream ends") }
	}

	func testInputIsAckedAndEchoesAndRateLimited() throws {
		let clock = TerminalTestClock()
		let backend = FakeTerminalBackend()
		let session = PhoneTerminalSession(
			agentID: "w1:p1", device: device(), backend: backend, mode: .mirror,
			phoneSize: TerminalSize(cols: 50, rows: 20), idleTimeout: 1800, clock: { clock.now })
		try session.start(timeout: 1)
		let (generation, _) = session.attach(after: nil)
		_ = drain(session, generation)
		XCTAssertEqual(try session.handle(.input(seq: 9, Data("x".utf8))), 9)
		XCTAssertEqual(drain(session, generation), [.output(2, "x"), .ack(9)])
		var accepted = 1
		for seq in 10..<400 where try session.handle(.input(seq: UInt32(seq), Data("y".utf8))) != nil { accepted += 1 }
		XCTAssertEqual(accepted, 300, "a one-second burst of 300 frames")
		clock.now += 1
		XCTAssertNotNil(try session.handle(.input(seq: 500, Data("z".utf8))))
		XCTAssertNil(try session.handle(.input(seq: 501, Data(count: 300 * 1024))), "over the byte budget")
		for seq in 600..<1200 { _ = try? session.handle(.input(seq: UInt32(seq), Data("y".utf8))) }
		XCTAssertTrue(session.isEnded, "sustained abuse ends the session")
		XCTAssertTrue(backend.stopped)
	}

	func testFitResizesThePaneAndEveryWayOutRestoresTheOriginal() throws {
		let clock = TerminalTestClock()
		let backend = FakeTerminalBackend()
		let session = PhoneTerminalSession(
			agentID: "w1:p1", device: device(), backend: backend, mode: .mirror,
			phoneSize: TerminalSize(cols: 50, rows: 20), idleTimeout: 1800, clock: { clock.now })
		try session.start(timeout: 1)
		try session.handle(.resize(TerminalSize(cols: 52, rows: 21)))
		XCTAssertEqual(backend.resized, [], "mirror never resizes the pane")
		try session.handle(.mode(.fit))
		try session.handle(.resize(TerminalSize(cols: 60, rows: 25)))
		XCTAssertEqual(backend.resized, [TerminalSize(cols: 52, rows: 21), TerminalSize(cols: 60, rows: 25)])
		try session.handle(.mode(.mirror))
		XCTAssertEqual(backend.unfitTo, TerminalSize(cols: 120, rows: 40))
		try session.handle(.mode(.fit))
		XCTAssertNil(session.expiry(now: clock.now + 60, grace: 30), "never detached: no grace deadline")
		XCTAssertEqual(session.expiry(now: clock.now + 1800, grace: 30), .idle)
		session.end(.idle)
		XCTAssertEqual(backend.stopRestore, TerminalSize(cols: 120, rows: 40))

		let other = PhoneTerminalSession(
			agentID: "w1:p1", device: device(), backend: FakeTerminalBackend(), mode: .mirror,
			phoneSize: TerminalSize(cols: 50, rows: 20), idleTimeout: 1800, clock: { clock.now })
		try other.start(timeout: 1)
		let (generation, _) = other.attach(after: nil)
		other.detach(generation)
		XCTAssertNil(other.expiry(now: clock.now + 29, grace: 30))
		XCTAssertEqual(other.expiry(now: clock.now + 30, grace: 30), .ended)
	}

	// MARK: Limits and targets

	func testOpenLimiterAllowsTwentyAMinute() {
		var limiter = TerminalOpenLimiter()
		for _ in 0..<20 { XCTAssertTrue(limiter.admit("dev", now: 100)) }
		XCTAssertFalse(limiter.admit("dev", now: 110))
		XCTAssertTrue(limiter.admit("other", now: 110))
		XCTAssertTrue(limiter.admit("dev", now: 160))
	}

	func testTargetsAreValidatedBeforeAnythingRuns() throws {
		XCTAssertEqual(try TerminalBridge.parseTarget("w1:p1"), .herdr(pane: "w1:p1"))
		XCTAssertEqual(try TerminalBridge.parseTarget("tmux:p12"), .tmux(pane: "12"))
		for bad in ["tmux:p1;rm -rf ~", "tmux:p", "tmux:%1", "w1:p1;rm", "w1:p1 rm", "-w1", "$(reboot)", "", "tmux:p1\n"] {
			XCTAssertThrowsError(try TerminalBridge.parseTarget(bad), bad) { XCTAssertEqual(($0 as? APIError)?.status, 400) }
		}
		XCTAssertThrowsError(try TerminalBridge.parseTarget("m_mini.w1:p1")) {
			XCTAssertEqual(($0 as? APIError)?.code, "not_supported")
		}
	}

	func testUnknownHerdrPanesAreRefused() throws {
		let rig = try FakeHerdrRig()
		defer { rig.stop() }
		let helper = try TestDaemon(herdrSocket: rig.localSocket)
		defer { helper.stop() }
		XCTAssertNoThrow(try helper.daemon.terminals.checkTarget(.herdr(pane: "w1:p1")))
		XCTAssertThrowsError(try helper.daemon.terminals.checkTarget(.herdr(pane: "w9:p9"))) {
			XCTAssertEqual(($0 as? APIError)?.status, 404)
		}
	}

	func testBridgeCapsSessionsReplacesAndRevokes() throws {
		var config = HelperConfig(paths: .init(config: "/nonexistent", stateDir: "/tmp", log: "/dev/null"))
		config.herdrCLI = ""
		config.tmuxCLI = ""
		let bridge = TerminalBridge(config: config, log: { _, _ in })
		var backends: [FakeTerminalBackend] = []
		bridge.makeBackend = { _ in
			let backend = FakeTerminalBackend()
			backends.append(backend)
			return backend
		}
		bridge.checkTarget = { _ in }
		let phone = device()
		let size = TerminalSize(cols: 50, rows: 20)
		for pane in 1...4 {
			_ = try bridge.open(agentID: "w1:p\(pane)", device: phone, size: size, mode: .mirror, resume: nil, after: nil)
		}
		XCTAssertThrowsError(try bridge.open(agentID: "w1:p5", device: phone, size: size, mode: .mirror, resume: nil, after: nil)) {
			XCTAssertEqual(($0 as? APIError)?.code, "too_many_terminals")
		}
		let (old, oldGeneration) = try bridge.open(
			agentID: "w1:p6", device: device("dev_bbbbbbbbbbbbbbbbbbbbbbbb"), size: size, mode: .mirror, resume: nil, after: nil)
		_ = drainAll(old, oldGeneration)
		let (fresh, _) = try bridge.open(
			agentID: "w1:p6", device: device("dev_bbbbbbbbbbbbbbbbbbbbbbbb"), size: size, mode: .mirror, resume: nil, after: nil)
		XCTAssertNotEqual(fresh.id, old.id)
		XCTAssertEqual(drainAll(old, oldGeneration).last, .exit("replaced"))
		let (resumed, _) = try bridge.open(
			agentID: "w1:p6", device: device("dev_bbbbbbbbbbbbbbbbbbbbbbbb"), size: size, mode: .mirror, resume: fresh.id,
			after: 1)
		XCTAssertTrue(resumed === fresh)

		bridge.entitled = { $0.deviceID != phone.deviceID }
		let first = try bridge.session(agentID: "w1:p1", deviceID: phone.deviceID)
		bridge.sweep()
		XCTAssertTrue(first.isEnded)
		XCTAssertThrowsError(try bridge.session(agentID: "w1:p1", deviceID: phone.deviceID))
		XCTAssertNoThrow(try bridge.session(agentID: "w1:p6", deviceID: "dev_bbbbbbbbbbbbbbbbbbbbbbbb", id: fresh.id))
		bridge.closeAll()
		XCTAssertTrue(backends.allSatisfy(\.stopped))
	}

	func testOpensAreRateLimitedPerDevice() throws {
		var config = HelperConfig(paths: .init(config: "/nonexistent", stateDir: "/tmp", log: "/dev/null"))
		config.herdrCLI = ""
		config.tmuxCLI = ""
		let bridge = TerminalBridge(config: config, log: { _, _ in })
		bridge.makeBackend = { _ in FakeTerminalBackend() }
		bridge.checkTarget = { _ in }
		for _ in 0..<20 {
			_ = try bridge.open(
				agentID: "w1:p1", device: device(), size: TerminalSize(cols: 50, rows: 20), mode: .mirror, resume: nil, after: nil)
		}
		XCTAssertThrowsError(
			try bridge.open(
				agentID: "w1:p1", device: device(), size: TerminalSize(cols: 50, rows: 20), mode: .mirror, resume: nil, after: nil)
		) { XCTAssertEqual(($0 as? APIError)?.status, 429) }
		bridge.closeAll()
	}

	private func drainAll(_ session: PhoneTerminalSession, _ generation: Int) -> [Seen] {
		var out: [Seen] = []
		while case .frames(let frames) = session.next(generation, timeout: 0.2) { out += frames.map { Seen($0.1) } }
		return out
	}

	// MARK: Routes

	func testTerminalRoutesMatch() {
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/terminal/ws")?.name, "agents.terminal.ws")
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/terminal/ws")?.agentID, "w1:p1")
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/terminal")?.name, "agents.terminal")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1:p1/terminal/input")?.name, "agents.terminal.input")
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1:p1/terminal/resize")?.name, "agents.terminal.resize")
		XCTAssertNil(LinkAPI.match("POST", "/v1/agents/w1:p1/terminal/ws"))
		XCTAssertNil(LinkAPI.match("GET", "/v1/agents/w1:p1/terminal/other"))
		XCTAssertEqual(LinkAPI.match("GET", "/v1/agents/w1:p1/terminal/ws")?.auth, .signed)
	}

	func testTerminalOpenQueryParsing() throws {
		let open = try LinkAPI.parseTerminalOpen(["cols": "60", "rows": "30", "mode": "fit", "resume": "term_0123456789ab", "after": "42"])
		XCTAssertEqual(open.size, TerminalSize(cols: 60, rows: 30))
		XCTAssertEqual(open.mode, .fit)
		XCTAssertEqual(open.resume, "term_0123456789ab")
		XCTAssertEqual(open.after, 42)
		XCTAssertEqual(try LinkAPI.parseTerminalOpen([:]).mode, .mirror)
		XCTAssertThrowsError(try LinkAPI.parseTerminalOpen(["cols": "1"]))
		XCTAssertThrowsError(try LinkAPI.parseTerminalOpen(["mode": "huge"]))
		XCTAssertThrowsError(try LinkAPI.parseTerminalOpen(["resume": "../etc"]))
		XCTAssertThrowsError(try LinkAPI.parseTerminalOpen(["after": "-1"]))
	}
}

// MARK: End to end over a real socket

/// A blocking TCP client speaking raw HTTP and WebSocket frames.
final class RawClient {
	let fd: Int32
	private var buffer = Data()

	init(port: Int, host: String = "127.0.0.1") throws {
		fd = socket(AF_INET, SOCK_STREAM, 0)
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = in_port_t(UInt16(port).bigEndian)
		address.sin_addr.s_addr = inet_addr(host)
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		guard connected == 0 else { throw NSError(domain: "RawClient", code: Int(errno)) }
		var timeout = timeval(tv_sec: 5, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	}

	deinit { close(fd) }

	func send(_ data: Data) {
		_ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
	}

	private func fill() -> Bool {
		var chunk = [UInt8](repeating: 0, count: 65536)
		let count = recv(fd, &chunk, chunk.count, 0)
		guard count > 0 else { return false }
		buffer.append(contentsOf: chunk[0..<count])
		return true
	}

	/// The response head (status line and headers).
	func readHead() -> String? {
		while buffer.range(of: Data("\r\n\r\n".utf8)) == nil { guard fill() else { return nil } }
		let end = buffer.range(of: Data("\r\n\r\n".utf8))!
		let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
		buffer.removeSubrange(buffer.startIndex..<end.upperBound)
		return head
	}

	func readFrame() -> WebSocket.Frame? {
		while true {
			if let (frame, used) = try? WebSocket.decodeFrame(buffer, requireMask: false) {
				buffer.removeFirst(used)
				return frame
			}
			guard fill() else { return nil }
		}
	}

	/// The next binary message's terminal frame (skipping pings).
	func readTerminalFrame() -> Seen? {
		while let frame = readFrame() {
			if frame.opcode == .binary { return Seen(frame.payload) }
			if frame.opcode == .close { return nil }
		}
		return nil
	}

	func sendMasked(_ opcode: WebSocket.Opcode, _ payload: Data) {
		send(WebSocket.encode(opcode, payload, mask: [UInt8.random(in: 0...255), 1, 2, 3]))
	}
}

final class TerminalWebSocketTests: XCTestCase {
	func handshake(_ target: String, headers: [String: String]) -> Data {
		var request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		request += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
		for (name, value) in headers { request += "\(name): \(value)\r\n" }
		return Data((request + "\r\n").utf8)
	}

	func helperWithFakePanes(configure: (inout HelperConfig) -> Void = { _ in }) throws -> (TestDaemon, FakeBox) {
		let helper = try TestDaemon(configure: configure)
		let box = FakeBox()
		helper.daemon.terminals.checkTarget = { target in
			guard target == .herdr(pane: "w1:p1") else { throw APIError(404, "not_found", "agent not found") }
		}
		helper.daemon.terminals.makeBackend = { _ in
			let backend = FakeTerminalBackend()
			box.backend = backend
			return backend
		}
		return (helper, box)
	}

	final class FakeBox: @unchecked Sendable { var backend: FakeTerminalBackend? }

	func testSignedUpgradeSpeaksTheTerminalProtocol() async throws {
		let (helper, box) = try helperWithFakePanes()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let target = "/v1/agents/w1:p1/terminal/ws?cols=50&rows=20&mode=mirror"
		let signed = try phone.signed("GET", target)
		let client = try RawClient(port: helper.port)
		client.send(handshake(target, headers: signed.allHTTPHeaderFields ?? [:]))
		let head = try XCTUnwrap(client.readHead())
		XCTAssertTrue(head.hasPrefix("HTTP/1.1 101 "), head)
		XCTAssertTrue(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), head)
		guard case .hello(false, 120, 40) = try XCTUnwrap(client.readTerminalFrame()) else { return XCTFail("hello first") }
		XCTAssertEqual(client.readTerminalFrame(), .reset)
		XCTAssertEqual(client.readTerminalFrame(), .output(1, "\u{1B}[2Jscreen"))
		// A fragmented input frame, with a ping in between.
		let input = TerminalFrame.encodeClient(.input(seq: 3, Data("x".utf8)))
		client.send(WebSocket.encode(.binary, input.prefix(2), fin: false, mask: [1, 2, 3, 4]))
		client.send(WebSocket.encode(.ping, Data("hi".utf8), mask: [5, 6, 7, 8]))
		client.send(WebSocket.encode(.continuation, input.dropFirst(2), mask: [9, 9, 9, 9]))
		let pong = try XCTUnwrap(client.readFrame())
		XCTAssertEqual(pong, WebSocket.Frame(fin: true, opcode: .pong, payload: Data("hi".utf8)))
		XCTAssertEqual(client.readTerminalFrame(), .output(2, "x"))
		XCTAssertEqual(client.readTerminalFrame(), .ack(3))
		XCTAssertEqual(box.backend?.written, [Data("x".utf8)])

		// Revoking the device ends the session with `exit revoked`.
		_ = helper.daemon.devices.revoke(phone.deviceID)
		XCTAssertEqual(client.readTerminalFrame(), .exit("revoked"))
		XCTAssertTrue(box.backend?.stopped ?? false)
	}

	func testUnsignedUpgradeIs401AndUnknownPanesAre404() async throws {
		let (helper, _) = try helperWithFakePanes()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let client = try RawClient(port: helper.port)
		client.send(handshake("/v1/agents/w1:p1/terminal/ws", headers: [:]))
		let head = try XCTUnwrap(client.readHead())
		XCTAssertTrue(head.hasPrefix("HTTP/1.0 401 "), head)

		let target = "/v1/agents/w2:p9/terminal/ws"
		let other = try RawClient(port: helper.port)
		other.send(handshake(target, headers: try phone.signed("GET", target).allHTTPHeaderFields ?? [:]))
		XCTAssertTrue(try XCTUnwrap(other.readHead()).hasPrefix("HTTP/1.0 404 "))

		let missingKey = "/v1/agents/w1:p1/terminal/ws?cols=50&rows=20"
		let plain = try await SoftPhone.send(try phone.signed("GET", missingKey))
		XCTAssertEqual(plain.status, 400, "a plain GET is not a handshake")
	}

	func testSSEAndPostInputCarryTheSameFrames() async throws {
		let (helper, box) = try helperWithFakePanes()
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let target = "/v1/agents/w1:p1/terminal?cols=50&rows=20"
		let (bytes, response) = try await URLSession.shared.bytes(for: try phone.signed("GET", target))
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
		var lines = bytes.lines.makeAsyncIterator()
		func nextFrame() async throws -> (String, Seen)? {
			var id = ""
			while let line = try await lines.next() {
				if line.hasPrefix("id: ") { id = String(line.dropFirst(4)) }
				if line.hasPrefix("data: "), let data = Data(base64Encoded: String(line.dropFirst(6))) { return (id, Seen(data)) }
			}
			return nil
		}
		guard case .hello = try await nextFrame()?.1 else { return XCTFail("hello first") }
		let session = try helper.daemon.terminals.session(agentID: "w1:p1", deviceID: phone.deviceID)
		_ = try await nextFrame()
		let first = try await nextFrame()
		XCTAssertEqual(first?.0, "1")
		XCTAssertEqual(first?.1, .output(1, "\u{1B}[2Jscreen"))
		let input = TerminalFrame.encodeClient(.input(seq: 11, Data("ls".utf8))).base64EncodedString()
		let posted = try await phone.call(
			"POST", "/v1/agents/w1:p1/terminal/input", json: ["session": session.id, "data": input])
		XCTAssertEqual(posted.status, 200)
		XCTAssertEqual(posted.json["ack"] as? Int, 11)
		let echoed = try await nextFrame()
		XCTAssertEqual(echoed?.0, "2")
		XCTAssertEqual(echoed?.1, .output(2, "ls"))
		let wrong = try await phone.call(
			"POST", "/v1/agents/w1:p1/terminal/input", json: ["session": "term_000000000000", "data": input])
		XCTAssertEqual(wrong.status, 404)
		let resized = try await phone.call("POST", "/v1/agents/w1:p1/terminal/resize", json: ["cols": 70, "rows": 30])
		XCTAssertEqual(resized.status, 200)
		XCTAssertEqual(box.backend?.resized, [], "mirror mode records the size only")
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("terminal_beta"))
	}
}
