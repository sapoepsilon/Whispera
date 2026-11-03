import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// More than 200 agents on each machine, and working agents whose long reads herdr refuses
/// (`agent_not_idle`): every agent reaches the phone, directly and over the relay, and a
/// working agent's output is its visible screen instead of a 502.
final class LargeAgentListTests: XCTestCase {
	static let perMachine = 250

	var rig: FakeHerdrRig!

	override func setUpWithError() throws {
		rig = try FakeHerdrRig(localAgents: Self.perMachine, remoteAgents: Self.perMachine)
	}

	override func tearDown() {
		rig.stop()
	}

	private func configure(_ config: inout HelperConfig) {
		config.herdrSocket = rig.localSocket
		config.herdrCLI = rig.cli
	}

	private static func checkList(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
		let agents = try XCTUnwrap(json["agents"] as? [[String: Any]], file: file, line: line)
		let ids = agents.compactMap { $0["id"] as? String }
		XCTAssertEqual(ids.count, 2 * perMachine, file: file, line: line)
		XCTAssertEqual(Set(ids).count, ids.count, "ids are unique", file: file, line: line)
		XCTAssertEqual(ids.filter { $0.hasPrefix("m_fake-main.") }.count, perMachine, file: file, line: line)
		XCTAssertTrue(
			agents.allSatisfy { ($0["title"] as? String)?.count ?? 0 > 60 }, "long titles survive", file: file,
			line: line)
	}

	func testEveryAgentOfTwoLargeMachinesIsListedDirectly() async throws {
		let helper = try TestDaemon(engine: FakeEngine(), configure: configure)
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let response = try await phone.call("GET", "/v1/agents")
		XCTAssertEqual(response.status, 200)
		XCTAssertGreaterThan(response.body.count, 64 * 1024, "the list is bigger than one relay frame")
		try Self.checkList(response.json)
		let list = try JSONDecoder().decode(AgentList.self, from: response.body)
		XCTAssertEqual(list.agents.count, 2 * Self.perMachine, "the phone's decoder keeps every agent")
	}

	func testWorkingAgentsOutputIsTheirVisibleScreenOnBothMachines() async throws {
		let helper = try TestDaemon(engine: FakeEngine(), configure: configure)
		defer { helper.stop() }
		let phone = try await helper.pairedPhone()
		let list = try await phone.call("GET", "/v1/agents")
		let agents = try XCTUnwrap(list.json["agents"] as? [[String: Any]])
		let working = agents.filter { $0["status"] as? String == "working" }.compactMap { $0["id"] as? String }
		let local = try XCTUnwrap(working.first { !$0.hasPrefix("m_") })
		let remote = try XCTUnwrap(working.first { $0.hasPrefix("m_") })
		for id in [local, remote] {
			let encoded = id.replacingOccurrences(of: ":", with: "%3A")
			let output = try await phone.call("GET", "/v1/agents/\(encoded)/output?source=recent&lines=200")
			XCTAssertEqual(output.status, 200, "\(id): \(String(decoding: output.body, as: UTF8.self))")
			XCTAssertEqual(output.json["source"] as? String, "visible", id)
			XCTAssertEqual(output.json["truncated"] as? Bool, true, id)
			let lines = (output.json["text"] as? String ?? "").split(separator: "\n")
			XCTAssertEqual(lines.count, 50, id)
		}
		let idle = try XCTUnwrap(agents.first { $0["status"] as? String == "idle" }?["id"] as? String)
		let output = try await phone.call(
			"GET", "/v1/agents/\(idle.replacingOccurrences(of: ":", with: "%3A"))/output?source=recent&lines=200")
		XCTAssertEqual(output.json["source"] as? String, "recent", "an idle agent still gets its history")
		XCTAssertEqual((output.json["text"] as? String ?? "").split(separator: "\n").count, 200)
	}

	func testEveryAgentArrivesOverTheRelayInFramesUnderTheCiphertextCap() async throws {
		let backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		let helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			self.configure(&config)
			config.accountPollWait = -1
			config.macName = "Test Mac"
		}
		defer { helper.stop() }
		let account = helper.daemon.account
		let accountPhone = AccountPhone(backend: backend)
		try await accountPhone.register(bearer: "tok-alice", name: "Test iPhone")
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		_ = try await account.confirmApprove(
			accountPhone.deviceID, safetyNumber: try accountPhone.safetyNumber(macID: macID))
		_ = try await accountPhone.receive()
		let relay = RelayPhone(accountPhone, macID: macID)

		let request = try relay.request("GET", "/v1/agents")
		try await relay.send(request)
		let response = try await relay.response(request.id, timeout: 20) { _ = try await account.syncNow() }
		XCTAssertEqual(response.status, 200)
		XCTAssertGreaterThan(relay.frames(request.id).count, 2, "the list travels as several parts")
		XCTAssertLessThanOrEqual(backend.largestCiphertext, FakeAccountBackend.maxCiphertextBytes)
		let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
		try Self.checkList(json)
	}
}
