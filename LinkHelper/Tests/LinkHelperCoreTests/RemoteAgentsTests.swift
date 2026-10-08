import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Two fake herdr servers (this Mac and the remote machine "fake-main") and the fake herdr CLI,
/// from `LinkHelper/e2e`. Every request they get is recorded; nothing here talks to a real herdr.
final class FakeHerdrRig {
	static let e2e = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
		.deletingLastPathComponent().appendingPathComponent("e2e")

	let directory: URL
	let localSocket: String
	let remoteSocket: String
	let cli: String
	let cliLog: String
	private var processes: [Process] = []

	/// `localAgents` / `remoteAgents`: serve that many generated agents instead of the presets.
	init(localAgents: Int? = nil, remoteAgents: Int? = nil) throws {
		// Short: AF_UNIX paths are limited to 104 bytes.
		directory = URL(fileURLWithPath: "/tmp/wlr-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		localSocket = directory.appendingPathComponent("l.sock").path
		remoteSocket = directory.appendingPathComponent("r.sock").path
		cli = directory.appendingPathComponent("herdr").path
		cliLog = directory.appendingPathComponent("cli.jsonl").path
		try launch(["--socket", localSocket] + (localAgents.map { ["--agents", String($0)] } ?? []))
		try launch(
			["--socket", remoteSocket, "--preset", "remote"]
				+ (remoteAgents.map { ["--agents", String($0), "--prefix", "r"] } ?? []))
		let config: [String: Any] = [
			"local_socket": localSocket, "log": cliLog,
			"machines": [
				["id": "fake-main", "label": "Fake Main Mac", "enabled": true, "socket": remoteSocket],
				["id": "fake-dead", "label": "Fake Dead Mac", "enabled": true, "unreachable": true],
				["id": "fake-off", "label": "Disabled Mac", "enabled": false, "socket": remoteSocket],
			],
		]
		let configPath = directory.appendingPathComponent("cli.json").path
		try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
		let wrapper =
			"#!/bin/sh\nexec /usr/bin/python3 '\(Self.e2e.appendingPathComponent("fake-herdr-cli").path)' --fake-config '\(configPath)' \"$@\"\n"
		try Data(wrapper.utf8).write(to: URL(fileURLWithPath: cli))
		chmod(cli, 0o755)
		let deadline = Date().addingTimeInterval(10)
		while !(FileManager.default.fileExists(atPath: localSocket) && FileManager.default.fileExists(atPath: remoteSocket))
		{
			guard Date() < deadline else { throw NSError(domain: "FakeHerdrRig", code: 1) }
			Thread.sleep(forTimeInterval: 0.05)
		}
	}

	private func launch(_ arguments: [String]) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = [Self.e2e.appendingPathComponent("fake_herdr.py").path] + arguments
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		processes.append(process)
	}

	func stop() {
		for process in processes where process.isRunning { process.terminate() }
		for process in processes { process.waitUntilExit() }
		try? FileManager.default.removeItem(at: directory)
	}

	/// One request to a fake (control methods start with `_fake.`).
	static func call(_ socket: String, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
		let connection = try UnixConnection.connect(path: socket, timeout: 2)
		defer { connection.close() }
		try connection.sendLine(["id": "t", "method": method, "params": params])
		guard case .line(let line) = try connection.readLine(timeout: 5) else { return [:] }
		return (WireJSON.decodeObject(line)?["result"] as? [String: Any]) ?? [:]
	}

	/// Every non-control request a fake received, as (method, params).
	func requests(_ socket: String) throws -> [(String, [String: Any])] {
		let list = try Self.call(socket, "_fake.requests")["requests"] as? [[Any]] ?? []
		return list.map { ($0.first as? String ?? "", $0.last as? [String: Any] ?? [:]) }
	}

	func writes(_ socket: String) throws -> [(String, [String: Any])] {
		let readOnly: Set<String> = ["ping", "agent.list", "agent.get", "agent.read", "events.subscribe", "workspace.list", "tab.list"]
		return try requests(socket).filter { !readOnly.contains($0.0) }
	}

	func cliInvocations() -> [[String]] {
		guard let text = try? String(contentsOfFile: cliLog, encoding: .utf8) else { return [] }
		return text.split(separator: "\n").compactMap {
			(WireJSON.decodeObject(Data($0.utf8))?["argv"] as? [String])
		}
	}
}

/// Agents on this Mac and on the other herdr machines (step 12, contract §2).
final class RemoteAgentsTests: XCTestCase {
	var rig: FakeHerdrRig!
	var helper: TestDaemon!
	var phone: SoftPhone!

	override func setUp() async throws {
		rig = try FakeHerdrRig()
		let rig = self.rig!
		helper = try TestDaemon(engine: FakeEngine()) { config in
			config.herdrSocket = rig.localSocket
			config.herdrCLI = rig.cli
		}
		phone = try await helper.pairedPhone()
	}

	override func tearDown() {
		helper.stop()
		rig.stop()
	}

	func testRemoteIDsAndLocalIDsParse() {
		XCTAssertEqual(AgentRef("w1:p1"), .local("w1:p1"))
		XCTAssertEqual(AgentRef("m_0123456789abcdef0123456789abcdef.wJ:p1"), .remote(machine: "0123456789abcdef0123456789abcdef", pane: "wJ:p1"))
		XCTAssertEqual(AgentRef.remoteID(machine: "fake-main", pane: "w9:p1"), "m_fake-main.w9:p1")
		XCTAssertTrue(LinkAPI.isValidAgentID(AgentRef.remoteID(machine: String(repeating: "a", count: 32), pane: "w12:p3")))
		XCTAssertEqual(LinkAPI.match("POST", "/v1/agents/w1%3Ap1/stop")?.name, "agents.stop")
		XCTAssertEqual(LinkAPI.match("PUT", "/v1/devices/me/push")?.name, "devices.push")
	}

	func testTheListHasEveryMachineAndAnUnreachableOneDoesNotFailIt() async throws {
		let response = try await phone.call("GET", "/v1/agents")
		XCTAssertEqual(response.status, 200)
		let agents = try XCTUnwrap(response.json["agents"] as? [[String: Any]])
		let ids = agents.compactMap { $0["id"] as? String }
		XCTAssertEqual(ids, ["w1:p1", "w1:p2", "w2:p1", "m_fake-main.w9:p1", "m_fake-main.w9:p2"])
		let remote = try XCTUnwrap(agents.first { $0["id"] as? String == "m_fake-main.w9:p1" })
		XCTAssertEqual(remote["machine"] as? [String: String], ["id": "fake-main", "label": "Fake Main Mac"])
		XCTAssertEqual(agents.first?["machine"] as? [String: String], ["id": "local", "label": "This Mac"])
		XCTAssertNil(remote["tokens"], "remote agents are mapped like local ones")
		XCTAssertEqual(response.json["herdr_version"] as? String, "0.9.1")

		let machines = try XCTUnwrap(response.json["machines"] as? [[String: Any]])
		XCTAssertEqual(machines.map { $0["id"] as? String }, ["local", "fake-main", "fake-dead"], "disabled machines are left out")
		XCTAssertEqual(machines.map { $0["status"] as? String }, ["ok", "ok", "unreachable"])
		XCTAssertNotNil(machines[2]["error"] as? String)
		XCTAssertEqual(machines[1]["label"] as? String, "Fake Main Mac")

		// Within 5 s the CLI is not asked again.
		let before = rig.cliInvocations().count
		_ = try await phone.call("GET", "/v1/agents")
		XCTAssertEqual(rig.cliInvocations().count, before)

		let get = try await phone.call("GET", "/v1/agents/m_fake-main.w9%3Ap2")
		XCTAssertEqual((get.json["agent"] as? [String: Any])?["status"] as? String, "working")
		let output = try await phone.call("GET", "/v1/agents/m_fake-main.w9%3Ap1/output?lines=2&source=recent_unwrapped")
		XCTAssertEqual(output.json["text"] as? String, "w9:p1 line 299\nw9:p1 line 300\n")
		let missing = try await phone.call("GET", "/v1/agents/m_fake-dead.w1%3Ap1")
		XCTAssertEqual(missing.status, 503)
		let unknown = try await phone.call("GET", "/v1/agents/m_nosuch.w1%3Ap1")
		XCTAssertEqual(unknown.errorCode, "not_found")
	}

	func testRemoteControlsGoThroughTheCLIToThatMachineOnly() async throws {
		let prompt = try await phone.call(
			"POST", "/v1/agents/m_fake-main.w9%3Ap1/prompt", json: ["text": "run the tests", "wait": ["until": ["idle"]]])
		XCTAssertEqual(prompt.status, 200)
		XCTAssertEqual((prompt.json["agent"] as? [String: Any])?["id"] as? String, "m_fake-main.w9:p1")
		let keys = try await phone.call("POST", "/v1/agents/m_fake-main.w9%3Ap1/keys", json: ["keys": ["esc", "enter"]])
		XCTAssertEqual(keys.json["keys"] as? Int, 2)
		let interrupt = try await phone.call("POST", "/v1/agents/m_fake-main.w9%3Ap1/interrupt", json: ["key": "ctrl+c"])
		XCTAssertEqual(interrupt.status, 200)
		let stop = try await phone.call("POST", "/v1/agents/m_fake-main.w9%3Ap2/stop")
		XCTAssertEqual(stop.status, 200)
		XCTAssertEqual(stop.json["id"] as? String, "m_fake-main.w9:p2")
		XCTAssertEqual(stop.json["stopped"] as? Bool, true)
		let dashed = try await phone.call("POST", "/v1/agents/m_fake-main.w9%3Ap1/prompt", json: ["text": "--help"])
		XCTAssertEqual(dashed.errorCode, "bad_request")

		let writes = try rig.writes(rig.remoteSocket)
		XCTAssertEqual(writes.map(\.0), ["agent.prompt", "agent.send_keys", "agent.send_keys", "agent.send_keys"])
		XCTAssertEqual(writes[0].1["text"] as? String, "run the tests")
		XCTAssertEqual((writes[0].1["wait"] as? [String: Any])?["until"] as? [String], ["idle"])
		XCTAssertEqual(writes[1].1["keys"] as? [String], ["esc", "enter"])
		XCTAssertEqual(writes[2].1["keys"] as? [String], ["ctrl+c"])
		XCTAssertEqual(writes[3].1["target"] as? String, "w9:p2")
		XCTAssertEqual(writes[3].1["keys"] as? [String], ["ctrl+c", "ctrl+c"])
		XCTAssertTrue(try rig.writes(rig.localSocket).isEmpty, "nothing was sent to this Mac's herdr")
	}

	func testStopSendsCtrlCTwiceToALocalAgent() async throws {
		let stop = try await phone.call("POST", "/v1/agents/w1%3Ap1/stop")
		XCTAssertEqual(stop.json["stopped"] as? Bool, true)
		let writes = try rig.writes(rig.localSocket)
		XCTAssertEqual(writes.map(\.0), ["agent.send_keys"])
		XCTAssertEqual(writes[0].1["target"] as? String, "w1:p1")
		XCTAssertEqual(writes[0].1["keys"] as? [String], ["ctrl+c", "ctrl+c"])
		let missing = try await phone.call("POST", "/v1/agents/w7%3Ap7/stop")
		XCTAssertEqual(missing.errorCode, "not_found")
	}

	func testStartWithoutAPaneOpensATabFirst() async throws {
		let local = try await phone.call("POST", "/v1/agents", json: ["name": "fixer", "kind": "codex", "workspace_id": "w2"])
		XCTAssertEqual(local.status, 200)
		let started = try XCTUnwrap(local.json["agent"] as? [String: Any])
		XCTAssertEqual(started["name"] as? String, "fixer")
		XCTAssertEqual(started["machine"] as? [String: String], ["id": "local", "label": "This Mac"])
		let localWrites = try rig.writes(rig.localSocket)
		XCTAssertEqual(localWrites.map(\.0), ["tab.create", "agent.start"])
		XCTAssertEqual(localWrites[0].1["label"] as? String, "fixer")
		XCTAssertEqual(localWrites[0].1["focus"] as? Bool, false)
		XCTAssertEqual(localWrites[0].1["workspace_id"] as? String, "w2")
		XCTAssertEqual(localWrites[1].1["pane_id"] as? String, started["id"] as? String)
		XCTAssertEqual(localWrites[1].1["kind"] as? String, "codex")

		let remote = try await phone.call(
			"POST", "/v1/agents", json: ["name": "far", "kind": "gemini", "machine": "fake-main", "cwd": "/tmp/work"])
		XCTAssertEqual(remote.status, 200)
		let remoteAgent = try XCTUnwrap(remote.json["agent"] as? [String: Any])
		XCTAssertTrue((remoteAgent["id"] as? String ?? "").hasPrefix("m_fake-main."))
		let remoteWrites = try rig.writes(rig.remoteSocket)
		XCTAssertEqual(remoteWrites.map(\.0), ["tab.create", "agent.start"])
		XCTAssertEqual(remoteWrites[0].1["cwd"] as? String, "/tmp/work")
		XCTAssertEqual(remoteWrites[0].1["label"] as? String, "far")
		XCTAssertEqual(remoteWrites[1].1["name"] as? String, "far")

		// An existing pane: no tab.
		let inPane = try await phone.call(
			"POST", "/v1/agents", json: ["name": "again", "kind": "codex", "pane_id": "w1:p1"])
		XCTAssertEqual(inPane.errorCode, "herdr_error", "the fake refuses a pane that already runs an agent")
		XCTAssertEqual(try rig.writes(rig.localSocket).map(\.0), ["tab.create", "agent.start", "agent.start"])
		let badMachine = try await phone.call("POST", "/v1/agents", json: ["name": "x", "kind": "codex", "machine": "nosuch"])
		XCTAssertEqual(badMachine.errorCode, "not_found")
	}

	func testRemoteStatusChangesArePolledIntoEvents() throws {
		let events = EventLog()
		let poller = RemoteAgentPoller(
			directory: helper.daemon.agents, interval: 3600, isListening: { true }, emit: { events.append($0, $1) })
		poller.pollOnce()
		XCTAssertTrue(events.all.isEmpty, "the first poll is the baseline")

		_ = try FakeHerdrRig.call(rig.remoteSocket, "_fake.set_status", ["pane_id": "w9:p1", "status": "blocked"])
		poller.pollOnce()
		XCTAssertEqual(events.all.map(\.0), ["agent.status"])
		XCTAssertEqual(events.all.first?.1["id"] as? String, "m_fake-main.w9:p1")
		XCTAssertEqual(events.all.first?.1["status"] as? String, "blocked")
		XCTAssertEqual((events.all.first?.1["machine"] as? [String: Any])?["id"] as? String, "fake-main")

		_ = try FakeHerdrRig.call(rig.remoteSocket, "_fake.add_pane", ["pane_id": "w9:p3", "agent": "codex"])
		poller.pollOnce()
		XCTAssertEqual(events.all.map(\.0), ["agent.status", "agents.changed"])
	}
}

final class EventLog: @unchecked Sendable {
	private let lock = NSLock()
	private var events: [(String, [String: Any])] = []

	func append(_ name: String, _ data: [String: Any]) {
		lock.lock()
		events.append((name, data))
		lock.unlock()
	}

	var all: [(String, [String: Any])] {
		lock.lock()
		defer { lock.unlock() }
		return events
	}
}
