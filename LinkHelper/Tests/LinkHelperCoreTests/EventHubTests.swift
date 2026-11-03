import XCTest

@testable import LinkHelperCore

/// §5.5: resume from the ring, `resync` outside it, at most two streams per device.
final class EventHubTests: XCTestCase {
	private func frames(_ stream: EventHub.Stream) -> [String] {
		var out: [String] = []
		while case .frame(let data) = stream.next(timeout: 0.01) {
			out.append(String(decoding: data, as: UTF8.self))
		}
		return out
	}

	func testResumeReplaysOnlyLaterEvents() {
		let hub = EventHub()
		for index in 1...3 { hub.publish("agents.changed", ["n": index]) }
		let (stream, last) = hub.subscribe(deviceID: "dev_a", lastEventID: "1")
		XCTAssertEqual(last, 3)
		XCTAssertEqual(frames(stream).map { $0.components(separatedBy: "\n")[0] }, ["id: 2", "id: 3"])
	}

	func testStaleOrFutureLastEventIDGetsOneResyncAtTheCurrentSeq() {
		let hub = EventHub()
		for index in 0..<(EventHub.ringSize + 10) { hub.publish("agents.changed", ["n": index]) }
		for lastID in ["1", "99999", "abc"] {
			let (stream, last) = hub.subscribe(deviceID: "dev_\(lastID)", lastEventID: lastID)
			XCTAssertEqual(frames(stream), ["id: \(last)\nevent: resync\ndata: {}\n\n"], lastID)
		}
	}

	func testThirdStreamClosesTheOldestAndRevokeClosesTheRest() {
		let hub = EventHub()
		let (first, _) = hub.subscribe(deviceID: "dev_a", lastEventID: nil)
		let (second, _) = hub.subscribe(deviceID: "dev_a", lastEventID: nil)
		let (third, _) = hub.subscribe(deviceID: "dev_a", lastEventID: nil)
		XCTAssertEqual(first.next(timeout: 0.01), .closed)
		XCTAssertEqual(hub.streamCount(deviceID: "dev_a"), 2)
		XCTAssertEqual(hub.closeDevice("dev_a"), 2)
		XCTAssertEqual(second.next(timeout: 0.01), .closed)
		XCTAssertEqual(third.next(timeout: 0.01), .closed)
	}
}
