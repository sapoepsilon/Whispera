import WhisperaAgents
import WhisperaTmux
import XCTest

@testable import LinkHelperCore

/// Pasted prompt text only types: a carriage return or Ctrl-C in it never acts as a key. Keys
/// (Enter, Ctrl-C) go through the explicit key APIs, unchanged.
final class PastedTextTests: XCTestCase {
	func testSanitizeStripsControlsButKeepsNewlinesAndTabs() {
		XCTAssertEqual(PastedText.sanitize("one\r\ntwo\rthree\u{03}four"), "one\ntwothreefour")
		XCTAssertEqual(PastedText.sanitize("a\tb\nc"), "a\tb\nc")
		XCTAssertEqual(PastedText.sanitize("x\u{04}\u{1A}\u{7F}\u{9B}y\u{08}"), "xy")
		XCTAssertEqual(PastedText.sanitize("héllo ✓ 日本"), "héllo ✓ 日本")
		XCTAssertEqual(PastedText.sanitize("\r\u{03}"), "")
	}

	final class Recorder: @unchecked Sendable {
		var calls: [[String]] = []
	}

	func testTmuxPasteStripsControlsAndKeysStayIntact() throws {
		let recorder = Recorder()
		let client = TmuxClient { arguments in
			recorder.calls.append(arguments)
			return ""
		}
		try client.send("echo hi\r\nrm -rf /\r\u{03}done", to: "%1")
		XCTAssertEqual(recorder.calls.count, 2)
		XCTAssertEqual(recorder.calls[0], ["send-keys", "-t", "%1", "-l", "--", "\u{1B}[200~echo hi\nrm -rf /done\u{1B}[201~"])
		XCTAssertEqual(recorder.calls[1], ["send-keys", "-t", "%1", "Enter"])
		XCTAssertThrowsError(try client.send("\r\u{03}", to: "%1"))

		recorder.calls = []
		try client.sendKeys(["enter", "ctrl+c"], to: "%1")
		XCTAssertEqual(recorder.calls, [["send-keys", "-t", "%1", "Enter", "C-c"]])
	}

	/// The helper's prompt route cleans the text for every backend; here through a fake `tmux`
	/// that records its arguments.
	func testAgentPromptPastesCleanText() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("wl-paste-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let panes = root.appendingPathComponent("panes")
		let fields = ["%1", "$1", "qa", "@1", "agent", "", root.path, "zsh", "1", "0"]
		try Data((fields.joined(separator: TmuxClient.separator) + "\n").utf8).write(to: panes)
		let log = root.appendingPathComponent("log")
		let script = root.appendingPathComponent("tmux")
		try Data(
			"""
			#!/bin/sh
			if [ "$1" = "list-panes" ]; then cat '\(panes.path)'; exit 0; fi
			printf '%s\\036' "$@" >> '\(log.path)'
			printf '\\035' >> '\(log.path)'

			""".utf8
		).write(to: script)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		let tmux = try XCTUnwrap(TmuxDirectory(configured: script.path))
		let directory = AgentDirectory(
			local: HerdrClient(socketPath: root.appendingPathComponent("missing.sock").path), cli: HerdrCLI(configured: ""), tmux: tmux)

		_ = try directory.prompt("tmux:p1", text: "first line\r\nsecond\r\u{03}", wait: nil)
		let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\u{1D}").map {
			$0.split(separator: "\u{1E}", omittingEmptySubsequences: false).dropLast().map(String.init)
		}
		XCTAssertEqual(calls.first, ["send-keys", "-t", "%1", "-l", "--", "\u{1B}[200~first line\nsecond\u{1B}[201~"])
		XCTAssertEqual(calls.last, ["send-keys", "-t", "%1", "Enter"])

		XCTAssertThrowsError(try directory.prompt("tmux:p1", text: "\r\u{03}", wait: nil))
		XCTAssertThrowsError(try directory.prompt("tmux:p1", text: "bad\u{1B}[201~payload", wait: nil))
	}
}
