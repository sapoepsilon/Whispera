import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A stand-in for /usr/bin/ssh: `fake-main.ts` runs the helper's remote script in a sandbox
/// whose only herdr is the fake CLI on the fake remote socket (PATH has none, as over a real
/// non-interactive ssh); any other host is refused like a down machine. Never a real ssh or herdr.
final class FakeSSH {
	let path: String
	let log: String
	let remoteLog: String

	/// `mainHasHerdr: false`: the remote script answers as on a machine with no herdr.
	init(rig: FakeHerdrRig, mainHasHerdr: Bool = true) throws {
		let root = URL(fileURLWithPath: rig.cliLog).deletingLastPathComponent()
		let home = root.appendingPathComponent("remote-home")
		let bin = home.appendingPathComponent(".local/bin")
		try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
		log = root.appendingPathComponent("ssh.log").path
		remoteLog = root.appendingPathComponent("remote-cli.jsonl").path
		let config = root.appendingPathComponent("remote-cli.json").path
		try JSONSerialization.data(withJSONObject: ["local_socket": rig.remoteSocket, "log": remoteLog])
			.write(to: URL(fileURLWithPath: config))
		let herdr = bin.appendingPathComponent("herdr").path
		try Data(
			"#!/bin/sh\nexec /usr/bin/python3 '\(FakeHerdrRig.e2e.appendingPathComponent("fake-herdr-cli").path)' --fake-config '\(config)' \"$@\"\n"
				.utf8
		).write(to: URL(fileURLWithPath: herdr))
		chmod(herdr, 0o755)
		path = root.appendingPathComponent("ssh").path
		let main =
			mainHasHerdr
			? "exec /usr/bin/env -i HOME='\(home.path)' PATH=/usr/bin:/bin /bin/sh -c \"$2\""
			: "echo '\(HerdrCLI.notFound)' >&2; exit 127"
		let script = """
			#!/bin/sh
			while [ "$1" != "--" ]; do shift; done
			shift
			echo "$1" >> '\(log)'
			case "$1" in
			  fake-main.ts) \(main) ;;
			  *) echo "ssh: connect to host ${1%.ts} port 22: Connection refused" >&2; exit 255 ;;
			esac

			"""
		try Data(script.utf8).write(to: URL(fileURLWithPath: path))
		chmod(path, 0o755)
	}

	/// The hosts ssh was asked for, one per connection.
	func connections() -> [String] {
		((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
	}

	/// What the remote herdr was asked to run.
	func remoteCommands() -> [[String]] {
		guard let text = try? String(contentsOfFile: remoteLog, encoding: .utf8) else { return [] }
		return text.split(separator: "\n").compactMap { WireJSON.decodeObject(Data($0.utf8))?["argv"] as? [String] }
	}
}

/// `GET /v1/agents` and the ask screen read without waiting on `herdr --machine`: one ssh
/// connection per batch, a short-lived cache served stale while it refreshes, one fetch per
/// machine at a time.
final class RemoteListSpeedTests: XCTestCase {
	var rig: FakeHerdrRig!

	override func setUpWithError() throws {
		rig = try FakeHerdrRig()
	}

	override func tearDown() {
		rig.stop()
	}

	private func directory(ssh: String?) -> AgentDirectory {
		AgentDirectory(local: HerdrClient(socketPath: rig.localSocket), cli: HerdrCLI(configured: rig.cli, ssh: ssh))
	}

	private func machine(_ directory: AgentDirectory, _ id: String = "fake-main") throws -> HerdrCLI.Machine {
		try XCTUnwrap(directory.cli.machines().first { $0.id == id })
	}

	private func canonical(_ object: Any) throws -> String {
		String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
	}

	private func machineCalls(_ id: String = "fake-main") -> [[String]] {
		rig.cliInvocations().filter { $0.starts(with: ["--machine", id]) }
	}

	// MARK: Direct path

	func testTheListIsOneSSHRoundTripPerMachineAndTheSameAsTheCLIPath() throws {
		let ssh = try FakeSSH(rig: rig)
		let direct = try directory(ssh: ssh.path).list()
		XCTAssertEqual(ssh.connections().filter { $0 == "fake-main.ts" }.count, 1, "agent, workspace and tab lists in one connection")
		XCTAssertEqual(ssh.remoteCommands(), [["agent", "list"], ["workspace", "list"], ["tab", "list"]])
		XCTAssertTrue(machineCalls().isEmpty, "herdr --machine is not run for fake-main")

		let viaCLI = try directory(ssh: nil).list()
		XCTAssertEqual(try canonical(direct), try canonical(viaCLI), "the same answer, field for field")
		let statuses = try XCTUnwrap(direct["machines"] as? [[String: Any]])
		XCTAssertEqual(statuses.map { $0["status"] as? String }, ["ok", "ok", "unreachable"])
	}

	func testAnUnreachableMachineIsNotTriedAgainThroughTheCLI() throws {
		let ssh = try FakeSSH(rig: rig)
		let listed = try directory(ssh: ssh.path).list()
		let dead = try XCTUnwrap((listed["machines"] as? [[String: Any]])?.first { $0["id"] as? String == "fake-dead" })
		XCTAssertEqual(dead["status"] as? String, "unreachable")
		XCTAssertTrue((dead["error"] as? String ?? "").contains("Connection refused"))
		XCTAssertTrue(machineCalls("fake-dead").isEmpty)
	}

	func testAMachineWithoutHerdrOnTheDirectPathFallsBackToTheCLI() throws {
		let ssh = try FakeSSH(rig: rig, mainHasHerdr: false)
		let directory = self.directory(ssh: ssh.path)
		let listed = try directory.list()
		let ids = (listed["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(ids.filter { $0.hasPrefix("m_fake-main.") }, ["m_fake-main.w9:p1", "m_fake-main.w9:p2"])
		XCTAssertEqual(machineCalls().map { Array($0.dropFirst(2)) }.sorted { $0.joined() < $1.joined() },
			[["agent", "list"], ["tab", "list"], ["workspace", "list"]])
		// The direct path stays off for that machine: no second ssh attempt.
		_ = try directory.get("m_fake-main.w9:p1")
		XCTAssertEqual(ssh.connections().filter { $0 == "fake-main.ts" }.count, 1)
	}

	func testRemoteReadsAndRefusalsAreTheSameOverTheDirectPath() throws {
		let ssh = try FakeSSH(rig: rig)
		let direct = directory(ssh: ssh.path)
		let reads = [("recent_unwrapped", 2), ("recent", 200)]
		let viaSSH = try reads.map { try direct.read("m_fake-main.w9:p2", source: $0.0, lines: $0.1, ansi: true) }
		// herdr's agent_not_idle came back on stderr through ssh, so the read fell back to the screen.
		XCTAssertEqual(viaSSH[1]["historyPartial"] as? Bool, true)
		XCTAssertThrowsError(try direct.get("m_fake-main.w9:p7")) { error in
			XCTAssertEqual((error as? APIError)?.code, "not_found", "a refusal, not an unreachable machine")
		}
		XCTAssertTrue(machineCalls().isEmpty, "all of it over ssh")

		let viaCLI = directory(ssh: nil)
		for (index, read) in reads.enumerated() {
			let b = try viaCLI.read("m_fake-main.w9:p2", source: read.0, lines: read.1, ansi: true)
			XCTAssertEqual(try canonical(viaSSH[index]), try canonical(b), read.0)
		}
	}

	func testAnAskReadsTextAndAnsiInOneRoundTripAndKeysReachOnlyThatPane() throws {
		let ssh = try FakeSSH(rig: rig)
		let directory = self.directory(ssh: ssh.path)
		let terminal = try directory.askTerminal("m_fake-main.w9:p1")
		let screen = try terminal.read()
		XCTAssertFalse(screen.text.isEmpty)
		XCTAssertNotNil(screen.ansi)
		XCTAssertEqual(ssh.connections().count, 1)
		XCTAssertEqual(
			ssh.remoteCommands().map { $0.last }, ["text", "ansi"], "both formats in the one connection")

		try terminal.send(keys: ["esc"])
		let writes = try rig.writes(rig.remoteSocket)
		XCTAssertEqual(writes.map(\.0), ["agent.send_keys"])
		XCTAssertEqual(writes.first?.1["target"] as? String, "w9:p1")
		XCTAssertEqual(writes.first?.1["keys"] as? [String], ["esc"])
		XCTAssertTrue(try rig.writes(rig.localSocket).isEmpty)

		// After keys the screen is read again, never the copy from before them.
		_ = try terminal.read()
		XCTAssertEqual(ssh.connections().count, 3)
	}

	func testTheRemoteScriptQuotesEveryArgument() throws {
		let tricky = ["it's", "$HOME", "a b", "`id`", "\"q\"", ";", "\\n"]
		for text in tricky {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/bin/sh")
			process.arguments = ["-c", "printf %s " + HerdrCLI.shellQuote(text)]
			let pipe = Pipe()
			process.standardOutput = pipe
			try process.run()
			process.waitUntilExit()
			XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), text)
		}
		XCTAssertTrue(HerdrCLI.directScript([["agent", "list"]]).hasSuffix(#"exec "$C" 'agent' 'list'"#))
	}

	func testBatchOutputSplitsIntoOneAnswerPerCommand() {
		let output = Data(
			("motd noise\n\n\(HerdrCLI.readyMarker)\n{\"id\":\"cli:agent:list\",\"result\":{\"type\":\"agent_list\"}}\n\n"
				+ "\(HerdrCLI.endMarker) 0\n{\"error\":{\"code\":\"x\",\"message\":\"m\"}}\n\n\(HerdrCLI.endMarker) 1\n").utf8)
		let result = HerdrCLI.RunResult(status: 1, stdout: output, stderr: Data())
		XCTAssertEqual(HerdrCLI.classify(result), .answer)
		let segments = HerdrCLI.segments(output, count: 2)
		XCTAssertEqual(segments.map(\.status), [0, 1])
		XCTAssertEqual((try? HerdrCLI.answer(segments[0]))?["type"] as? String, "agent_list")
		XCTAssertNotNil(HerdrCLI.herdrError(segments[1]))
		XCTAssertTrue(HerdrCLI.segments(output, count: 3).isEmpty, "a cut-off batch is not half-trusted")
		let refused = HerdrCLI.RunResult(status: 255, stdout: Data(), stderr: Data("ssh: connect refused\n".utf8))
		XCTAssertEqual(HerdrCLI.classify(refused), .unreachable)
		let noHerdr = HerdrCLI.RunResult(status: 127, stdout: Data(), stderr: Data((HerdrCLI.notFound + "\n").utf8))
		XCTAssertEqual(HerdrCLI.classify(noHerdr), .unsupported)
	}

	// MARK: Cache

	func testAStaleListIsAnsweredAtOnceAndReplacedInTheBackground() throws {
		let directory = self.directory(ssh: nil)
		let start = Date()
		directory.now = { start }
		XCTAssertEqual(try status(directory.list(), "m_fake-main.w9:p1"), "idle")
		_ = try FakeHerdrRig.call(rig.remoteSocket, "_fake.set_status", ["pane_id": "w9:p1", "status": "blocked"])
		let lists = machineCalls().filter { $0.contains("list") && $0.contains("agent") }.count

		directory.now = { start.addingTimeInterval(HerdrCLI.cacheTTL + 5) }
		let served = Date()
		let stale = try directory.list()
		XCTAssertLessThan(Date().timeIntervalSince(served), 0.5, "no wait on the machine")
		XCTAssertEqual(try status(stale, "m_fake-main.w9:p1"), "idle", "the last-known list")
		let main = try XCTUnwrap((stale["machines"] as? [[String: Any]])?.first { $0["id"] as? String == "fake-main" })
		XCTAssertEqual(main["stale"] as? Bool, true)
		XCTAssertEqual(main["status"] as? String, "ok")

		let deadline = Date().addingTimeInterval(10)
		var fresh = try directory.list()
		while try status(fresh, "m_fake-main.w9:p1") != "blocked", Date() < deadline {
			Thread.sleep(forTimeInterval: 0.05)
			fresh = try directory.list()
		}
		XCTAssertEqual(try status(fresh, "m_fake-main.w9:p1"), "blocked")
		XCTAssertNil((fresh["machines"] as? [[String: Any]])?.first { $0["id"] as? String == "fake-main" }?["stale"])
		XCTAssertEqual(
			machineCalls().filter { $0.contains("list") && $0.contains("agent") }.count, lists + 1, "one background fetch")
	}

	func testAListPastTheStaleWindowIsFetchedBeforeAnswering() throws {
		let directory = self.directory(ssh: nil)
		let start = Date()
		directory.now = { start }
		_ = try directory.list()
		_ = try FakeHerdrRig.call(rig.remoteSocket, "_fake.set_status", ["pane_id": "w9:p1", "status": "blocked"])
		directory.now = { start.addingTimeInterval(AgentDirectory.staleTTL + 1) }
		let listed = try directory.list()
		XCTAssertEqual(try status(listed, "m_fake-main.w9:p1"), "blocked")
		XCTAssertNil((listed["machines"] as? [[String: Any]])?.first { $0["id"] as? String == "fake-main" }?["stale"])
	}

	func testAnUnreachableMachineIsNeverServedFromAnOldList() throws {
		let directory = self.directory(ssh: nil)
		let start = Date()
		directory.now = { start }
		_ = try directory.list()
		directory.now = { start.addingTimeInterval(HerdrCLI.cacheTTL + 5) }
		let dead = try XCTUnwrap((try directory.list()["machines"] as? [[String: Any]])?.first { $0["id"] as? String == "fake-dead" })
		XCTAssertEqual(dead["status"] as? String, "unreachable")
		XCTAssertNil(dead["stale"])
	}

	func testConcurrentListsShareOneFetchPerMachine() throws {
		let directory = self.directory(ssh: nil)
		let main = try machine(directory)
		let ok = Counter()
		DispatchQueue.concurrentPerform(iterations: 8) { _ in
			if case .success(let agents) = directory.remoteAgents(main), agents.count == 2 { ok.add() }
		}
		XCTAssertEqual(ok.value, 8)
		XCTAssertEqual(machineCalls().filter { $0.suffix(2) == ["agent", "list"] }.count, 1)
		// The status poller asks for a fresh list: that is a new fetch.
		_ = directory.remoteAgents(main, fresh: true)
		XCTAssertEqual(machineCalls().filter { $0.suffix(2) == ["agent", "list"] }.count, 2)
	}

	private func status(_ listed: [String: Any], _ id: String) throws -> String? {
		try XCTUnwrap((listed["agents"] as? [[String: Any]])?.first { $0["id"] as? String == id })["status"] as? String
	}
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
