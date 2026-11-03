import Foundation
import WhisperaAgents
import WhisperaHerdr
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A fake herdr-core (`LinkHelper/e2e/fake_hc.py`) on its own socket. Every request it gets is
/// recorded; nothing here talks to a real hc.
final class FakeHCRig {
	let directory: URL
	let socket: String
	private let process: Process

	init(heartbeat: Double = 15) throws {
		// Short: AF_UNIX paths are limited to 104 bytes.
		directory = URL(fileURLWithPath: "/tmp/whc-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		socket = directory.appendingPathComponent("hc.sock").path
		process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = [
			FakeHerdrRig.e2e.appendingPathComponent("fake_hc.py").path, "--socket", socket, "--heartbeat", String(heartbeat),
		]
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		let deadline = Date().addingTimeInterval(10)
		while !FileManager.default.fileExists(atPath: socket) {
			guard Date() < deadline else { throw NSError(domain: "FakeHCRig", code: 1) }
			Thread.sleep(forTimeInterval: 0.05)
		}
	}

	func stop() {
		if process.isRunning { process.terminate() }
		process.waitUntilExit()
		try? FileManager.default.removeItem(at: directory)
	}

	@discardableResult
	func control(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
		let connection = try UnixConnection.connect(path: socket, timeout: 2)
		defer { connection.close() }
		try connection.sendLine(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
		guard case .line(let line) = try connection.readLine(timeout: 5) else { return [:] }
		return (WireJSON.decodeObject(line)?["result"] as? [String: Any]) ?? [:]
	}

	func requests() throws -> [(String, [String: Any])] {
		let list = try control("_fake.requests")["requests"] as? [[Any]] ?? []
		return list.map { ($0.first as? String ?? "", $0.last as? [String: Any] ?? [:]) }
	}

	/// What reached hc beyond detection and reads.
	func writes() throws -> [(String, [String: Any])] {
		let reads: Set<String> = ["hello", "terminal.list", "terminal.get", "terminal.read", "events.subscribe"]
		return try requests().filter { !reads.contains($0.0) }
	}
}

final class HerdrCoreIDTests: XCTestCase {
	func testIDsRoundTripAndArePathSafe() {
		XCTAssertEqual(HerdrCoreID.id(address: "t9"), "hc:t9")
		XCTAssertEqual(HerdrCoreID.id(address: "t1b"), "hc:t1b")
		XCTAssertEqual(HerdrCoreID.id(address: "mac-b/t7"), "hc:mac-b:t7")
		for address in ["t9", "t1b", "mac-b/t7", "dev.box_2/t1k"] {
			let id = try! XCTUnwrap(HerdrCoreID.id(address: address))
			XCTAssertEqual(HerdrCoreID.address(id), address)
			XCTAssertTrue(LinkAPI.isValidAgentID(id), id)
			XCTAssertFalse(id.contains("/"))
		}
		XCTAssertEqual(HerdrCoreID.machine("hc:mac-b:t7"), "mac-b")
		XCTAssertNil(HerdrCoreID.machine("hc:t7"))
		XCTAssertTrue(HerdrCoreID.isRemote("hc:mbp:t7"))
		XCTAssertFalse(HerdrCoreID.isRemote("hc:t7"))
		XCTAssertFalse(HerdrCoreID.isHerdrCore("tmux:p1"))
	}

	func testMalformedAddressesAndIDsAreRefused() {
		for address in ["", "x9", "t", "T9", "t9/x", "a/b/t9", "-x/t9", ".x/t9", "m:x/t9", "t9;rm", "t1 2", "t_1"] {
			XCTAssertNil(HerdrCoreID.id(address: address), address)
		}
		for id in ["hc:", "hc:t", "hc:x9", "hc:-m:t9", "hc:m:t9:t1", "hc:m/t9", "hc:t9 ", "t9", "hc:m:", "hc::t9"] {
			XCTAssertNil(HerdrCoreID.address(id), id)
		}
	}

	func testHerdrCoreIDsAreNotOldHerdrRemotes() {
		XCTAssertEqual(AgentRef("hc:mbp:t7"), .local("hc:mbp:t7"))
		XCTAssertEqual(try TerminalBridge.parseTarget("hc:t1"), .herdrCore(address: "t1"))
		XCTAssertEqual(try TerminalBridge.parseTarget("hc:mbp:t7"), .herdrCore(address: "mbp/t7"))
		XCTAssertThrowsError(try TerminalBridge.parseTarget("hc:t1:x:y"))
	}

	func testProjectionOfATerminal() {
		let terminal: [String: Any] = [
			"address": "t2", "state": "live", "title": "Disk cleanup", "turn": 20,
			"status": ["app": "claude-code", "state": "blocked", "kind": "permission", "msg": "may I?"],
			"foreground": ["argv": ["claude", "--resume"], "cwd": "/Users/u/repo", "name": "2.1.317", "pid": 68466],
			"labels": ["herdr.space": "sp1", "herdr.tab": "tb1", "where": "disk cleanup / 1"], "cwd": "/Users/u",
		]
		let agent = HerdrCoreAgent.agent(terminal, machine: ["id": "local", "label": "This Mac"])!
		XCTAssertEqual(agent["id"] as? String, "hc:t2")
		XCTAssertEqual(agent["provider"] as? String, "hc")
		XCTAssertEqual(agent["agent"] as? String, "claude")
		XCTAssertEqual(agent["status"] as? String, "blocked")
		XCTAssertEqual(agent["status_kind"] as? String, "permission")
		XCTAssertEqual(agent["name"] as? String, "disk cleanup")
		XCTAssertEqual(agent["tab_label"] as? String, "1")
		XCTAssertEqual(agent["workspace_id"] as? String, "hc:sp1")
		XCTAssertEqual(agent["cwd"] as? String, "/Users/u/repo")
		XCTAssertEqual(agent["turn"] as? Int, 20)
		XCTAssertEqual(agent["focused"] as? Bool, false)

		let shell: [String: Any] = [
			"address": "t1k", "state": "live", "status": NSNull(), "title": "",
			"foreground": ["argv": ["/bin/zsh", "-l"], "cwd": "/Users/u", "name": "zsh", "pid": 1],
		]
		let plain = HerdrCoreAgent.agent(shell, machine: [:])!
		XCTAssertTrue(plain["agent"] is NSNull, "a shell is no agent: stop and remove see nothing to end")
		XCTAssertEqual(plain["display_agent"] as? String, "zsh", "the phone still shows it, not a bare shell")
		XCTAssertEqual(plain["status"] as? String, "unknown")
		XCTAssertEqual(HerdrCoreAgent.status(["status": ["state": "napping"]]), "unknown", "words hc adds later are unknown")
	}
}

final class HerdrCoreClientTests: XCTestCase {
	var rig: FakeHCRig!

	override func setUp() async throws { rig = try FakeHCRig() }
	override func tearDown() { rig.stop() }

	func testHelloDetectsACapableCore() throws {
		let client = HerdrCoreClient(socketPath: rig.socket)
		let capabilities = try XCTUnwrap(client.capabilities(fresh: true))
		XCTAssertEqual(capabilities.version, "0.1.17")
		XCTAssertTrue(capabilities.canStart)
		XCTAssertTrue(capabilities.canRemove)
		let hello = try XCTUnwrap(rig.requests().first { $0.0 == "hello" })
		XCTAssertEqual(hello.1["generation"] as? Int, 1)
	}

	func testDetectionNeedsTheStatusFeatureTheMethodsAndGenerationOne() throws {
		let client = HerdrCoreClient(socketPath: rig.socket)
		try rig.control("_fake.hello", ["features": ["events", "attach"]])
		XCTAssertNil(client.capabilities(fresh: true), "no self-reported status, no agents")
		try rig.control("_fake.hello", ["methods": ["hello", "terminal.list"]])
		XCTAssertNil(client.capabilities(fresh: true))
		try rig.control("_fake.hello", ["generation": 2])
		XCTAssertNil(client.capabilities(fresh: true))
		try rig.control("_fake.hello", [:])
		XCTAssertNotNil(client.capabilities(fresh: true))
		XCTAssertNil(HerdrCoreClient(socketPath: rig.directory.appendingPathComponent("none.sock").path).capabilities(fresh: true))
	}

	func testDetectionIsCached() throws {
		let client = HerdrCoreClient(socketPath: rig.socket)
		_ = client.capabilities()
		_ = client.capabilities()
		_ = client.capabilities()
		XCTAssertEqual(try rig.requests().filter { $0.0 == "hello" }.count, 1)
	}

	func testTheMethodAllowlistIsClosed() throws {
		let client = HerdrCoreClient(socketPath: rig.socket)
		for method in ["machine.exec", "file.write", "server.stop", "terminal.label", "terminal.attach", "events.subscribe", "_fake.clear"] {
			XCTAssertThrowsError(try client.call(method, [:]), method) { error in
				XCTAssertEqual((error as? APIError)?.code, "internal")
			}
		}
		XCTAssertTrue(try rig.requests().isEmpty, "nothing reached the socket")
	}

	func testErrorsMapByKind() throws {
		let client = HerdrCoreClient(socketPath: rig.socket)
		XCTAssertThrowsError(try client.call("terminal.get", ["terminal": "t99"])) { error in
			XCTAssertEqual((error as? APIError)?.status, 404)
			XCTAssertEqual((error as? APIError)?.extra["hc_kind"] as? String, "not_found")
		}
		XCTAssertThrowsError(try client.call("terminal.send", ["terminal": "t3", "text": "hi"])) { error in
			XCTAssertEqual((error as? APIError)?.code, "agent_blocked")
		}
		XCTAssertThrowsError(try client.call("terminal.rm", ["terminal": "t1"])) { error in
			XCTAssertEqual((error as? APIError)?.code, "still_running")
		}
		XCTAssertThrowsError(try HerdrCoreClient(socketPath: "/tmp/no-such-hc.sock").call("terminal.list")) { error in
			XCTAssertEqual((error as? APIError)?.code, "hc_unavailable")
		}
	}
}

final class HerdrCoreDirectoryTests: XCTestCase {
	var rig: FakeHCRig!
	var hc: HerdrCoreDirectory!

	override func setUp() async throws {
		rig = try FakeHCRig()
		hc = HerdrCoreDirectory(socketPath: rig.socket, claudeSessionsDir: rig.directory.path)
	}

	override func tearDown() { rig.stop() }

	func testListProjectsEveryLiveTerminalAndTheMachines() throws {
		let (agents, machines) = try hc.list()
		XCTAssertEqual(agents.compactMap { $0["id"] as? String }, ["hc:t1", "hc:t2", "hc:t3", "hc:mbp:t7"])
		let t1 = try XCTUnwrap(agents.first)
		XCTAssertEqual(t1["status"] as? String, "done")
		XCTAssertEqual(t1["agent"] as? String, "claude")
		XCTAssertEqual(t1["name"] as? String, "repo work")
		XCTAssertEqual(t1["machine"] as? [String: String], ["id": "local", "label": "This Mac"])
		let remote = try XCTUnwrap(agents.last)
		XCTAssertEqual(remote["machine"] as? [String: String], ["id": "mbp", "label": "mac-b"])
		XCTAssertEqual(remote["status"] as? String, "working")
		XCTAssertEqual(machines.map { $0["id"] as? String }, ["mbp", "dead"])
		XCTAssertEqual(machines.map { $0["status"] as? String }, ["ok", "unreachable"])
		XCTAssertNotNil(machines[1]["error"])
		try rig.control("_fake.finish", ["address": "t2"])
		XCTAssertFalse(try hc.list().agents.contains { $0["id"] as? String == "hc:t2" }, "finished terminals leave the list")
	}

	func testAnIDTheListingLacksNeverReachesHC() throws {
		try rig.control("_fake.clear")
		for id in ["hc:t99", "hc:nosuch:t1", "hc:dead:t1"] {
			XCTAssertThrowsError(try hc.send("hi", id: id), id) { XCTAssertEqual(($0 as? APIError)?.code, "not_found") }
			XCTAssertThrowsError(try hc.sendKeys(["enter"], id: id), id)
			XCTAssertThrowsError(try hc.read(id, source: "visible", lines: 10), id)
		}
		XCTAssertThrowsError(try hc.send("hi", id: "hc:t1/../t2")) { XCTAssertEqual(($0 as? APIError)?.code, "bad_request") }
		XCTAssertEqual(try rig.requests().map(\.0).filter { $0 != "terminal.list" && $0 != "hello" }, [])
	}

	func testReads() throws {
		let visible = try hc.read("hc:t1", source: "visible", lines: 200)
		XCTAssertEqual(visible["text"] as? String, "screen of t1\n> ")
		XCTAssertEqual(visible["truncated"] as? Bool, false)
		let history = try hc.read("hc:t1", source: "recent", lines: 3)
		XCTAssertTrue((history["text"] as? String ?? "").hasPrefix("history 0\n"))
		let busy = try hc.read("hc:mbp:t7", source: "recent", lines: 200)
		XCTAssertEqual(busy["truncated"] as? Bool, true)
		XCTAssertEqual(busy["historyPartial"] as? Bool, true)
		XCTAssertEqual(busy["format"] as? String, "text")
		let reads = try rig.requests().filter { $0.0 == "terminal.read" }.map { ($0.1["terminal"] as? String, $0.1["lines"] as? Int) }
		XCTAssertEqual(reads.map(\.0), ["t1", "t1", "mbp/t7"])
		XCTAssertEqual(reads.map(\.1), [0, 3, 200])
		XCTAssertThrowsError(try hc.read("hc:t1", source: "detection", lines: 80), "unknown sources fall back to visible upstream")
	}

	func testSendAndKeys() throws {
		let sent = try hc.send("fix it\nplease", id: "hc:t1")
		XCTAssertEqual((sent["agent"] as? [String: Any])?["id"] as? String, "hc:t1")
		XCTAssertThrowsError(try hc.send("hi", id: "hc:t3")) { XCTAssertEqual(($0 as? APIError)?.code, "agent_blocked") }
		_ = try hc.sendKeys(["Enter", "esc", "y", "ctrl+c"], id: "hc:mbp:t7")
		for bad in [["rm -rf /"], ["\u{1B}"], [], Array(repeating: "a", count: 65), ["--force"]] {
			XCTAssertThrowsError(try hc.sendKeys(bad, id: "hc:t1"), "\(bad)")
		}
		let writes = try rig.writes()
		XCTAssertEqual(writes.map(\.0), ["terminal.send", "terminal.keys"], "a blocked agent's send never reaches hc")
		XCTAssertEqual(writes[0].1["text"] as? String, "fix it\nplease")
		XCTAssertEqual(writes[0].1["terminal"] as? String, "t1")
		XCTAssertNil(writes[0].1["force"], "a blocked agent is never forced")
		XCTAssertEqual(writes[1].1["keys"] as? [String], ["enter", "esc", "y", "ctrl+c"])
		XCTAssertEqual(writes[1].1["terminal"] as? String, "mbp/t7")
	}

	func testStartRunsArgvNeverAShellLine() throws {
		let start = AgentStart(name: "Fix-1", kind: "claude", machine: nil, paneID: nil, workspaceID: nil, cwd: "/tmp/x",
			args: ["--model", "opus; rm -rf ~"], timeoutMS: 5000, provider: "hc")
		let started = try hc.start(start, machine: nil)
		let agent = try XCTUnwrap(started["agent"] as? [String: Any])
		XCTAssertEqual(agent["id"] as? String, "hc:t4")
		XCTAssertEqual(agent["name"] as? String, "Fix-1")
		_ = try hc.start(AgentStart(name: "r", kind: "codex", machine: "mbp", paneID: nil, workspaceID: nil, cwd: nil, args: [],
			timeoutMS: 5000), machine: "mbp")
		XCTAssertThrowsError(try hc.start(AgentStart(name: "x", kind: "bash", machine: nil, paneID: nil, workspaceID: nil,
			cwd: nil, args: ["-c", "id"], timeoutMS: 5000), machine: nil))
		XCTAssertThrowsError(try hc.start(AgentStart(name: "x", kind: "claude", machine: "nosuch", paneID: nil, workspaceID: nil,
			cwd: nil, args: [], timeoutMS: 5000), machine: "nosuch"))
		let runs = try rig.writes().filter { $0.0 == "terminal.run" }
		XCTAssertEqual(runs.count, 2)
		XCTAssertEqual(runs[0].1["argv"] as? [String], ["claude", "--model", "opus; rm -rf ~"])
		XCTAssertNil(runs[0].1["line"], "never a shell line")
		XCTAssertEqual(runs[0].1["cwd"] as? String, "/tmp/x")
		XCTAssertEqual(runs[0].1["labels"] as? [String: String], [HerdrCoreAgent.nameLabel: "Fix-1"])
		XCTAssertNil(runs[0].1["on"])
		XCTAssertEqual(runs[1].1["on"] as? String, "mbp")
	}

	func testRemoveEndsOnlyAgentsAndIsIdempotent() throws {
		XCTAssertThrowsError(try hc.remove("hc:t2")) { XCTAssertEqual(($0 as? APIError)?.code, "not_an_agent") }
		XCTAssertTrue(try rig.writes().isEmpty, "a plain shell is never killed from the phone")
		let removed = try hc.remove("hc:t1")
		XCTAssertEqual(removed["already_gone"] as? Bool, false)
		XCTAssertEqual(try rig.writes().map(\.0), ["terminal.kill", "terminal.rm"])
		XCTAssertEqual(try rig.writes().compactMap { $0.1["terminal"] as? String }, ["t1", "t1"])
		XCTAssertEqual(try hc.remove("hc:t1")["already_gone"] as? Bool, true)
		XCTAssertEqual(try rig.writes().count, 2)
	}

	func testAskTerminal() throws {
		let blocked = try hc.askTerminal("hc:t3")
		XCTAssertEqual(try blocked.blocked(), true)
		XCTAssertEqual(try hc.askTerminal("hc:t1").blocked(), false)
		try rig.control("_fake.set_text", ["terminal": "t3", "text": "Which one?\n❯ 1. A\n  2. B\n"])
		XCTAssertEqual(try blocked.read().text, "Which one?\n❯ 1. A\n  2. B\n")
		XCTAssertNil(try blocked.read().ansi)
		try blocked.send(keys: ["down", "enter"])
		try blocked.type("a B.")
		XCTAssertThrowsError(try blocked.type("ok!")) { error in
			guard case .invalidAnswer = error as? AgentAskError else { return XCTFail("\(error)") }
		}
		XCTAssertThrowsError(try blocked.type("café"))
		let keys = try rig.writes().filter { $0.0 == "terminal.keys" }.compactMap { $0.1["keys"] as? [String] }
		XCTAssertEqual(keys, [["down", "enter"], ["a", "space", "shift+b", "."]], "an untypable answer sends nothing")
		XCTAssertThrowsError(try hc.askTerminal("hc:t42"))
	}

	// MARK: Transcripts

	func writeSession(pid: Int, body: [String: Any]) throws {
		let data = try JSONSerialization.data(withJSONObject: body)
		try data.write(to: rig.directory.appendingPathComponent("\(pid).json"))
	}

	func testClaudeSessionFromItsPID() throws {
		let session = "0d6f9c1e-2b9a-4a7e-8c55-1f2e3d4c5b6a"
		try writeSession(pid: 4242, body: ["pid": 4242, "sessionId": session, "cwd": "/Users/me/repo"])
		let info = try XCTUnwrap(hc.transcriptInfo("hc:t1"))
		XCTAssertEqual(info["agent"] as? String, "claude")
		XCTAssertEqual(info["cwd"] as? String, "/Users/me/repo")
		XCTAssertEqual((info["agent_session"] as? [String: Any])?["value"] as? String, session)
		XCTAssertEqual(AgentTranscripts.sessionID(info), session)
		XCTAssertEqual(AgentTranscripts.harness(info), .claude)
	}

	func testSessionFilesFailSoft() throws {
		let session = "0d6f9c1e-2b9a-4a7e-8c55-1f2e3d4c5b6a"
		try writeSession(pid: 4242, body: ["pid": 4243, "sessionId": session])
		XCTAssertNil(hc.claudeSessionID(pid: 4242), "another process's file")
		try writeSession(pid: 4242, body: ["pid": 4242, "sessionId": "../../etc/passwd"])
		XCTAssertNil(hc.claudeSessionID(pid: 4242))
		try Data("not json".utf8).write(to: rig.directory.appendingPathComponent("4242.json"))
		XCTAssertNil(hc.claudeSessionID(pid: 4242))
		try FileManager.default.removeItem(at: rig.directory.appendingPathComponent("4242.json"))
		let elsewhere = rig.directory.appendingPathComponent("elsewhere.json")
		try JSONSerialization.data(withJSONObject: ["pid": 4242, "sessionId": session]).write(to: elsewhere)
		try FileManager.default.createSymbolicLink(at: rig.directory.appendingPathComponent("4242.json"), withDestinationURL: elsewhere)
		XCTAssertNil(hc.claudeSessionID(pid: 4242), "never through a link")
		XCTAssertNil(hc.claudeSessionID(pid: 0))
		let info = try XCTUnwrap(hc.transcriptInfo("hc:t1"))
		XCTAssertNil(info["agent_session"], "no session: the agent is still readable by folder")
		XCTAssertNil(try hc.transcriptInfo("hc:mbp:t7"), "other machines' logs aren't on this Mac")
		XCTAssertNil(try hc.transcriptInfo("hc:t2"), "a shell has no transcript")
		XCTAssertNil(try hc.transcriptInfo("hc:t77"))
	}

	func testATranscriptWithoutALogIsEmptyNotAnError() throws {
		let state = rig.directory.appendingPathComponent("transcripts.json").path
		let core = hc!
		let store = AgentTranscripts(
			readAgent: { pane in try core.transcriptInfo(pane) },
			locator: SessionLocator(claudeHome: rig.directory, codexHome: rig.directory), statePath: state)
		let live = try store.transcript("hc:t1", query: [:])
		XCTAssertEqual((live["entries"] as? [Any])?.count, 0)
		XCTAssertEqual(live["ended"] as? Bool, false)
		XCTAssertThrowsError(try store.transcript("hc:mbp:t7", query: [:])) {
			XCTAssertEqual(($0 as? APIError)?.code, "transcript_unavailable")
		}
	}
}

/// The agent list merges herdr, tmux and herdr-core; each answers or fails on its own.
final class HerdrCoreMergeTests: XCTestCase {
	var herdr: FakeHerdrRig!
	var rig: FakeHCRig!

	override func setUp() async throws {
		herdr = try FakeHerdrRig()
		rig = try FakeHCRig()
	}

	override func tearDown() {
		rig.stop()
		herdr.stop()
	}

	func directory(herdrSocket: String? = nil, hcSocket: String? = nil) -> AgentDirectory {
		AgentDirectory(
			local: HerdrClient(socketPath: herdrSocket ?? herdr.localSocket), cli: HerdrCLI(configured: ""),
			hc: HerdrCoreDirectory(socketPath: hcSocket ?? rig.socket, claudeSessionsDir: rig.directory.path))
	}

	func testBothProvidersAreListed() throws {
		let listed = try directory().list()
		let ids = (listed["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["w1:p1", "w1:p2", "w2:p1", "hc:t1", "hc:t2", "hc:t3", "hc:mbp:t7"])
		let machines = (listed["machines"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(machines, ["local", "mbp", "dead"])
		let providers = listed["providers"] as? [[String: Any]] ?? []
		XCTAssertEqual(providers.compactMap { $0["status"] as? String }, ["up", "up"])
		XCTAssertEqual(providers.last?["version"] as? String, "0.1.17")
	}

	func testOldHerdrDownStillListsHerdrCore() throws {
		let listed = try directory(herdrSocket: "/tmp/no-herdr-here.sock").list()
		let ids = (listed["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["hc:t1", "hc:t2", "hc:t3", "hc:mbp:t7"])
		let local = (listed["machines"] as? [[String: Any]])?.first
		XCTAssertEqual(local?["status"] as? String, "ok", "this Mac answers through herdr-core")
	}

	func testHerdrCoreAbsentChangesNothing() throws {
		let listed = try directory(hcSocket: "/tmp/no-hc-here.sock").list()
		let ids = (listed["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["w1:p1", "w1:p2", "w2:p1"])
		XCTAssertEqual((listed["machines"] as? [[String: Any]])?.count, 1)
		XCTAssertEqual((listed["providers"] as? [[String: Any]])?.last?["status"] as? String, "absent")
		XCTAssertThrowsError(try directory(herdrSocket: "/tmp/no-herdr-here.sock", hcSocket: "/tmp/no-hc-here.sock").list())
	}

	func testControlsRouteByPrefix() throws {
		let agents = directory()
		XCTAssertEqual((try agents.get("hc:t3")["agent"] as? [String: Any])?["status"] as? String, "blocked")
		_ = try agents.prompt("hc:t1", text: "go", wait: (until: ["idle"], timeoutMS: 1000))
		_ = try agents.sendKeys("hc:t1", keys: ["esc"])
		XCTAssertEqual(try rig.writes().map(\.0), ["terminal.send", "terminal.keys"])
		XCTAssertTrue(try herdr.writes(herdr.localSocket).isEmpty, "nothing went to the old herdr")
		XCTAssertThrowsError(try agents.codeReader("hc:mbp:t7")) { XCTAssertEqual(($0 as? APIError)?.code, "remote_machine") }
		XCTAssertThrowsError(try agents.imagePaths("hc:mbp:t7", paths: ["/tmp/a.jpg"], device: "d")) {
			XCTAssertEqual(($0 as? APIError)?.code, "image_transfer_failed")
		}
		XCTAssertEqual(try agents.imagePaths("hc:t1", paths: ["/tmp/a.jpg"], device: "d"), ["/tmp/a.jpg"])
		XCTAssertNotNil(try agents.askTerminal("hc:t3") as? HerdrCoreAskTerminal)
	}

	func testStartPicksTheProvider() throws {
		let agents = directory()
		func request(_ machine: String? = nil, provider: String? = nil, workspace: String? = nil) -> AgentStart {
			AgentStart(name: "n", kind: "claude", machine: machine, paneID: nil, workspaceID: workspace, cwd: nil, args: [],
				timeoutMS: 5000, provider: provider)
		}
		let hc = try XCTUnwrap(agents.hc)
		XCTAssertFalse(try agents.startsOnHerdrCore(request(), hc: hc), "the old herdr keeps this Mac while it runs")
		XCTAssertTrue(try agents.startsOnHerdrCore(request(provider: "hc"), hc: hc))
		XCTAssertTrue(try agents.startsOnHerdrCore(request("mbp"), hc: hc), "a machine only hc knows")
		XCTAssertTrue(try agents.startsOnHerdrCore(request(workspace: "hc:spA"), hc: hc))
		XCTAssertFalse(try agents.startsOnHerdrCore(request(provider: "herdr"), hc: hc))
		XCTAssertThrowsError(try agents.startsOnHerdrCore(request(provider: "screen"), hc: hc))
		let down = directory(herdrSocket: "/tmp/no-herdr-here.sock")
		XCTAssertTrue(try down.startsOnHerdrCore(request(), hc: try XCTUnwrap(down.hc)), "only hc is up")
		let started = try agents.start(request(provider: "hc"))
		XCTAssertEqual((started["agent"] as? [String: Any])?["id"] as? String, "hc:t4")
		XCTAssertThrowsError(try agents.start(AgentStart(name: "n", kind: "claude", machine: nil, paneID: "hc:t1",
			workspaceID: nil, cwd: nil, args: [], timeoutMS: 5000)))
		XCTAssertTrue(try herdr.writes(herdr.localSocket).isEmpty)
	}

	func testParseStartTakesAProvider() throws {
		let parsed = try LinkAPI.parseStart(["name": "a", "kind": "claude", "provider": "hc", "machine": "mac-b"])
		XCTAssertEqual(parsed.provider, "hc")
		XCTAssertNil(try LinkAPI.parseStart(["name": "a", "kind": "claude"]).provider)
		XCTAssertThrowsError(try LinkAPI.parseStart(["name": "a", "kind": "claude", "provider": "screen"]))
	}

	func testRemoveRoutesToHerdrCore() throws {
		let agents = directory()
		XCTAssertEqual(try agents.remove("hc:t3")["already_gone"] as? Bool, false)
		XCTAssertEqual(try rig.writes().map(\.0), ["terminal.kill", "terminal.rm"])
		XCTAssertTrue(try herdr.writes(herdr.localSocket).isEmpty)
	}
}

/// `events.subscribe`: statuses become the phone's agent.status, set changes agents.changed,
/// and a lost or behind subscription catches up from a fresh snapshot.
final class HerdrCoreEventTests: XCTestCase {
	final class Events: @unchecked Sendable {
		private let lock = NSLock()
		private var items: [(String, [String: Any])] = []
		func add(_ name: String, _ data: [String: Any]) {
			lock.lock()
			items.append((name, data))
			lock.unlock()
		}
		var all: [(String, [String: Any])] {
			lock.lock()
			defer { lock.unlock() }
			return items
		}
		func clear() {
			lock.lock()
			items = []
			lock.unlock()
		}
		func statuses() -> [String] {
			all.filter { $0.0 == "agent.status" }.map { "\($0.1["id"] ?? "") \($0.1["status"] ?? "")" }
		}
		func count(_ name: String) -> Int { all.filter { $0.0 == name }.count }
	}

	var rig: FakeHCRig!
	var events: Events!
	var subscriber: HerdrCoreSubscriber!

	func start(heartbeat: Double = 15, timeout: TimeInterval = 45) throws {
		rig = try FakeHCRig(heartbeat: heartbeat)
		events = Events()
		let directory = HerdrCoreDirectory(socketPath: rig.socket)
		let events = self.events!
		subscriber = HerdrCoreSubscriber(directory: directory, emit: { events.add($0, $1) }, backoffBase: 0.1, backoffMax: 0.2)
		subscriber.heartbeatTimeout = timeout
		subscriber.start()
		try wait { self.subscriber.state == .up && self.subscriber.snapshot().count == 4 }
	}

	override func tearDown() {
		subscriber?.stop()
		rig?.stop()
	}

	func wait(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition() {
			guard Date() < deadline else { throw NSError(domain: "HerdrCoreEventTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "condition not met in time"]) }
			Thread.sleep(forTimeInterval: 0.02)
		}
	}

	func expect(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
		XCTAssertTrue(condition(), message)
	}

	func testStatusEventsBecomeAgentStatus() throws {
		try start()
		XCTAssertTrue(events.all.isEmpty, "the first snapshot is only recorded")
		try rig.control("_fake.set_status", ["terminal": "t1", "state": "working"])
		try rig.control("_fake.set_status", ["terminal": "mbp/t7", "state": "blocked", "kind": "permission"])
		try rig.control("_fake.set_status", ["terminal": "mbp/t7", "state": "blocked", "kind": "permission"])
		expect("both statuses arrive") { self.events.statuses().count == 2 }
		XCTAssertEqual(events.statuses(), ["hc:t1 working", "hc:mbp:t7 blocked"], "an unchanged status is not repeated")
		let blocked = try XCTUnwrap(events.all.last?.1)
		XCTAssertEqual(blocked["status_kind"] as? String, "permission")
		XCTAssertEqual(blocked["machine"] as? [String: String], ["id": "mbp", "label": "mac-b"])
		XCTAssertEqual(blocked["provider"] as? String, "hc")
	}

	func testSetChangesAreAgentsChanged() throws {
		try start()
		try rig.control("_fake.add", ["address": "t20", "app": "claude-code", "argv": ["claude"]])
		expect("created") { self.events.count("agents.changed") == 1 }
		expect("the new terminal is known") { self.subscriber.snapshot()["hc:t20"] != nil }
		try rig.control("_fake.set_status", ["terminal": "t20", "state": "working"])
		expect("its status follows") { self.events.statuses() == ["hc:t20 working"] }
		try rig.control("_fake.finish", ["address": "t20"])
		expect("finished") { self.events.count("agents.changed") == 2 }
		XCTAssertNil(subscriber.snapshot()["hc:t20"])
	}

	func testMissedReplacesTheSnapshotAndReportsTheDifference() throws {
		try start()
		// Changes the subscriber never hears about, then hc says it fell behind.
		let held = try rig.control("_fake.drop")
		XCTAssertEqual(held["dropped"] as? Int, 1)
		try wait { self.subscriber.state == .up && (try? self.rig.control("_fake.subscribers")["count"] as? Int) == 1 }
		events.clear()
		try rig.control("_fake.missed", ["with_snapshot": true])
		Thread.sleep(forTimeInterval: 0.3)
		XCTAssertEqual(events.statuses(), [], "a snapshot equal to what is known reports nothing")
	}

	func testAReconnectCatchesUpOnWhatChangedMeanwhile() throws {
		try start()
		try rig.control("_fake.drop")
		// hc keeps going while the helper reconnects.
		try rig.control("_fake.set_status", ["terminal": "t3", "state": "working"])
		expect("the reconnect's snapshot shows the change") { self.events.statuses().contains("hc:t3 working") }
		expect("it reconnected") { self.subscriber.connections >= 2 }
	}

	func testSilenceBeyondTheHeartbeatReconnects() throws {
		try start(heartbeat: 0, timeout: 0.5)
		expect("a quiet connection is replaced") { self.subscriber.connections >= 2 }
	}

	func testHeartbeatsKeepItConnected() throws {
		try start(heartbeat: 0.2, timeout: 1)
		Thread.sleep(forTimeInterval: 1.6)
		XCTAssertEqual(subscriber.connections, 1)
	}

	func testAnAbsentCoreIsAbsentNotDown() throws {
		events = Events()
		let directory = HerdrCoreDirectory(socketPath: "/tmp/no-hc-\(UUID().uuidString.prefix(6)).sock")
		let events = self.events!
		subscriber = HerdrCoreSubscriber(directory: directory, emit: { events.add($0, $1) }, backoffBase: 0.05, backoffMax: 0.1)
		subscriber.start()
		expect("absent") { self.subscriber.state == .absent }
		Thread.sleep(forTimeInterval: 0.3)
		XCTAssertTrue(events.all.isEmpty, "no herdr.down noise for a core that was never there")
	}
}

/// The phone's view of herdr-core through a running helper.
final class HerdrCoreHelperTests: XCTestCase {
	var rig: FakeHCRig!
	var helper: TestDaemon!
	var phone: SoftPhone!

	override func setUp() async throws {
		rig = try FakeHCRig()
		let rig = self.rig!
		helper = try TestDaemon(engine: FakeEngine()) { config in config.hcSocket = rig.socket }
		phone = try await helper.pairedPhone()
	}

	override func tearDown() {
		helper.stop()
		rig.stop()
	}

	func testThePhoneListsReadsAndDrivesHerdrCoreAgents() async throws {
		let list = try await phone.call("GET", "/v1/agents")
		XCTAssertEqual(list.status, 200)
		let ids = (list.json["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["hc:t1", "hc:t2", "hc:t3", "hc:mbp:t7"], "herdr is down; herdr-core still answers")
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertEqual(health.json["hc"] as? String, "up")
		let get = try await phone.call("GET", "/v1/agents/hc%3Ambp%3At7")
		XCTAssertEqual((get.json["agent"] as? [String: Any])?["status"] as? String, "working")
		let output = try await phone.call("GET", "/v1/agents/hc%3At1/output?lines=50&source=visible")
		XCTAssertEqual(output.json["text"] as? String, "screen of t1\n> ")
		let prompt = try await phone.call("POST", "/v1/agents/hc%3At1/prompt", json: ["text": "hello there"])
		XCTAssertEqual(prompt.status, 200, "\(prompt.json)")
		let blocked = try await phone.call("POST", "/v1/agents/hc%3At3/prompt", json: ["text": "hello"])
		XCTAssertEqual(blocked.errorCode, "agent_blocked")
		let unknown = try await phone.call("GET", "/v1/agents/hc%3At404")
		XCTAssertEqual(unknown.status, 404)
		let sends = try rig.writes().filter { $0.0 == "terminal.send" }
		XCTAssertEqual(sends.compactMap { $0.1["text"] as? String }, ["hello there"])
	}
}

final class HerdrCoreTerminalTests: XCTestCase {
	func testTheHelloSaysReadOnly() throws {
		let hello = TerminalFrame.encodeHello(
			session: "s", size: TerminalSize(cols: 80, rows: 24), mode: .mirror, provider: "hc", resumed: false, idleTimeout: 60,
			readOnly: true)
		let object = try XCTUnwrap(WireJSON.decodeObject(hello.dropFirst()))
		XCTAssertEqual(object["read_only"] as? Bool, true)
		XCTAssertEqual(object["provider"] as? String, "hc")
		let plain = try XCTUnwrap(WireJSON.decodeObject(TerminalFrame.encodeHello(
			session: "s", size: TerminalSize(cols: 80, rows: 24), mode: .mirror, provider: "tmux", resumed: false,
			idleTimeout: 60).dropFirst()))
		XCTAssertNil(plain["read_only"])
	}

	func testTheBackendNeverTypesOrResizes() throws {
		let backend = HerdrCoreTerminalBackend(cli: "/usr/bin/false", address: "t1") { TerminalSize(cols: 80, rows: 24) }
		XCTAssertTrue(backend.readOnly)
		XCTAssertNoThrow(try backend.write(Data("rm -rf ~\r".utf8)))
		XCTAssertNoThrow(try backend.resizePane(TerminalSize(cols: 10, rows: 10)))
		XCTAssertNil(backend.paneSize)
	}
}
