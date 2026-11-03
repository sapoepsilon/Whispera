import Foundation
import WhisperaAgents
import WhisperaHerdr
import XCTest

@testable import LinkHelperCore

/// Against the real herdr-core on this Mac, only with `HC_LIVE_SMOKE=1`. It starts one
/// throwaway `cat` terminal of its own, drives only that one, and kills and removes it at the
/// end; every other terminal is only listed.
final class HerdrCoreLiveSmokeTests: XCTestCase {
	func testAThrowawayTerminalEndToEnd() throws {
		try XCTSkipIf(ProcessInfo.processInfo.environment["HC_LIVE_SMOKE"] != "1", "Set HC_LIVE_SMOKE=1 to run against the real hc.")
		let socket = NSHomeDirectory() + "/.local/state/herdr-core/default/default.sock"
		let cli = HerdrCLI.resolve("hc", environment: ProcessInfo.processInfo.environment)
		let hc = HerdrCoreDirectory(socketPath: socket, cli: cli)
		let capabilities = try XCTUnwrap(hc.client.capabilities(fresh: true), "hc did not pass detection")
		print("hc smoke: version \(capabilities.version)")

		let events = HerdrCoreEventTests.Events()
		let subscriber = HerdrCoreSubscriber(directory: hc, emit: { events.add($0, $1) })
		subscriber.start()
		defer { subscriber.stop() }

		let name = "whispera-smoke-" + UUID().uuidString.prefix(6).lowercased()
		let run = try hc.client.call(
			"terminal.run", ["argv": ["cat"], "name": name, "no_parent": true, "no_notify": true, "labels": ["whispera.smoke": "1"]],
			timeout: 15)
		let address = try XCTUnwrap(run["address"] as? String)
		XCTAssertFalse(address.contains("/"), "started on this machine")
		let id = try XCTUnwrap(HerdrCoreID.id(address: address))
		print("hc smoke: started \(address) as \(id)")
		var cleaned = false
		func cleanup() {
			guard !cleaned else { return }
			cleaned = true
			_ = try? hc.client.call("terminal.kill", ["terminal": address], timeout: 15)
			_ = try? hc.client.call("terminal.rm", ["terminal": address])
		}
		defer { cleanup() }

		// It appears in the merged list beside every other provider.
		let directory = AgentDirectory(
			local: HerdrClient(socketPath: NSHomeDirectory() + "/.config/herdr/herdr.sock"), cli: HerdrCLI(configured: ""), hc: hc)
		let listed = try directory.list()
		let agents = listed["agents"] as? [[String: Any]] ?? []
		let mine = try XCTUnwrap(agents.first { $0["id"] as? String == id }, "the throwaway terminal is listed")
		XCTAssertEqual(mine["provider"] as? String, "hc")
		XCTAssertEqual(mine["display_agent"] as? String, "cat")
		XCTAssertTrue(mine["agent"] is NSNull)
		let providers = (listed["providers"] as? [[String: Any]] ?? []).map { "\($0["id"] ?? "")=\($0["status"] ?? "")" }
		print("hc smoke: listed \(agents.count) agents; providers \(providers)")

		// send pastes and presses Enter; cat echoes the line back.
		_ = try directory.prompt(id, text: "smoke hello", wait: nil)
		_ = try directory.sendKeys(id, keys: ["h", "i", "space", "shift+x", ".", "enter"])
		let typed = try hc.askTerminal(id)
		try typed.type("Typed it, ok")
		XCTAssertThrowsError(try typed.type("no!"), "untypable text is refused before any key")
		_ = try directory.sendKeys(id, keys: ["enter"])
		var text = ""
		let deadline = Date().addingTimeInterval(8)
		repeat {
			text = try directory.read(id, source: "recent", lines: 50)["text"] as? String ?? ""
			if text.contains("smoke hello"), text.contains("hi X."), text.contains("Typed it, ok") { break }
			Thread.sleep(forTimeInterval: 0.2)
		} while Date() < deadline
		print("hc smoke: read back \(text.debugDescription)")
		XCTAssertTrue(text.contains("smoke hello"), "send reached it")
		XCTAssertTrue(text.contains("hi X."), "keys reached it")
		XCTAssertTrue(text.contains("Typed it, ok"), "typing reached it")
		XCTAssertFalse(
			text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("no") },
			"nothing of the refused text was typed")
		XCTAssertEqual(try typed.blocked(), false)

		// The read-only terminal view mirrors it.
		if cli != nil {
			let backend = HerdrCoreTerminalBackend(cli: cli!, address: address) {
				guard let terminal = try? hc.validated(id).terminal, let cols = terminal["cols"] as? Int, let rows = terminal["rows"] as? Int
				else { return nil }
				return TerminalSize(cols: cols, rows: rows)
			}
			let output = OutputBox()
			try backend.start { event in
				if case .output(let data, _, _) = event { output.append(data) }
			}
			let until = Date().addingTimeInterval(5)
			while output.count == 0, Date() < until { Thread.sleep(forTimeInterval: 0.1) }
			backend.stop(restore: nil)
			print("hc smoke: attach --observe sent \(output.count) bytes")
			XCTAssertGreaterThan(output.count, 0, "the observe attach painted the screen")
		}

		// The phone cannot remove a plain program; the smoke cleans up its own terminal.
		XCTAssertThrowsError(try directory.remove(id)) { XCTAssertEqual(($0 as? APIError)?.code, "not_an_agent") }
		cleanup()
		XCTAssertFalse(
			(try directory.list()["agents"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id }, "kill + rm removed it")
		let until = Date().addingTimeInterval(5)
		while events.count("agents.changed") == 0, Date() < until { Thread.sleep(forTimeInterval: 0.1) }
		print("hc smoke: events \(events.all.map(\.0))")
		XCTAssertGreaterThan(events.count("agents.changed"), 0, "the subscription saw it come and go")
	}

	final class OutputBox: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()
		func append(_ chunk: Data) {
			lock.lock()
			data.append(chunk)
			lock.unlock()
		}
		var count: Int {
			lock.lock()
			defer { lock.unlock() }
			return data.count
		}
	}
}
