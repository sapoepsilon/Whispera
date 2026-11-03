import Foundation
import XCTest

@testable import LinkHelperCore

/// `DELETE /v1/agents/{id}`: the phone removes an agent by closing its herdr pane, on this Mac
/// or on another herdr machine, against the fake herdr.
final class AgentRemoveTests: XCTestCase {
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

	private func listedIDs() async throws -> [String] {
		let list = try await phone.call("GET", "/v1/agents")
		return (list.json["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
	}

	func testTheRouteAndCapabilityExist() async throws {
		XCTAssertEqual(LinkAPI.match("DELETE", "/v1/agents/w1%3Ap1")?.name, "agents.remove")
		XCTAssertEqual(LinkAPI.match("DELETE", "/v1/agents/w1%3Ap1")?.auth, .signed)
		XCTAssertNil(LinkAPI.match("DELETE", "/v1/agents"))
		let health = try await phone.call("GET", "/v1/health")
		XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("agents_remove"))
	}

	func testRemovingALocalAgentClosesItsPaneAndItLeavesTheList() async throws {
		let response = try await phone.call("DELETE", "/v1/agents/w1%3Ap1")
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["id"] as? String, "w1:p1")
		XCTAssertEqual(response.json["removed"] as? Bool, true)
		XCTAssertEqual(response.json["already_gone"] as? Bool, false)
		let writes = try rig.writes(rig.localSocket)
		XCTAssertEqual(writes.map(\.0), ["pane.close"])
		XCTAssertEqual(writes[0].1["pane_id"] as? String, "w1:p1")
		let ids = try await listedIDs()
		XCTAssertFalse(ids.contains("w1:p1"))
		XCTAssertTrue(ids.contains("w1:p2"), "only that agent is removed")
		XCTAssertTrue(try rig.writes(rig.remoteSocket).isEmpty)
	}

	func testRemovingAWorkingRemoteAgentGoesThroughTheCLIToThatMachineOnly() async throws {
		let before = try await listedIDs()
		XCTAssertTrue(before.contains("m_fake-main.w9:p2"))
		let response = try await phone.call("DELETE", "/v1/agents/m_fake-main.w9%3Ap2")
		XCTAssertEqual(response.status, 200)
		XCTAssertEqual(response.json["id"] as? String, "m_fake-main.w9:p2")
		XCTAssertEqual(response.json["already_gone"] as? Bool, false)
		let writes = try rig.writes(rig.remoteSocket)
		XCTAssertEqual(writes.map(\.0), ["pane.close"])
		XCTAssertEqual(writes[0].1["pane_id"] as? String, "w9:p2")
		XCTAssertTrue(rig.cliInvocations().contains(["--machine", "fake-main", "pane", "close", "w9:p2"]))
		XCTAssertTrue(try rig.writes(rig.localSocket).isEmpty, "nothing was sent to this Mac's herdr")
		let after = try await listedIDs()
		XCTAssertFalse(after.contains("m_fake-main.w9:p2"), "the machine's cached list was dropped")
	}

	func testAnAgentThatIsAlreadyGoneIsRemovedWithoutClosingAnything() async throws {
		let local = try await phone.call("DELETE", "/v1/agents/w7%3Ap7")
		XCTAssertEqual(local.status, 200)
		XCTAssertEqual(local.json["already_gone"] as? Bool, true)
		let remote = try await phone.call("DELETE", "/v1/agents/m_fake-main.w9%3Ap7")
		XCTAssertEqual(remote.status, 200)
		XCTAssertEqual(remote.json["already_gone"] as? Bool, true)
		XCTAssertTrue(try rig.writes(rig.localSocket).isEmpty)
		XCTAssertTrue(try rig.writes(rig.remoteSocket).isEmpty)
	}

	/// A pane that only runs a shell (the agent exited) is the owner's terminal: never closed.
	func testAPlainShellPaneIsNeverClosed() async throws {
		let created = try FakeHerdrRig.call(rig.localSocket, "tab.create", ["workspace_id": "w1", "label": "shell"])
		let pane = try XCTUnwrap((created["root_pane"] as? [String: Any])?["pane_id"] as? String)
		try FakeHerdrRig.call(rig.localSocket, "_fake.clear")
		let encoded = pane.replacingOccurrences(of: ":", with: "%3A")
		let response = try await phone.call("DELETE", "/v1/agents/\(encoded)")
		XCTAssertEqual(response.json["already_gone"] as? Bool, true)
		XCTAssertFalse(try rig.writes(rig.localSocket).map(\.0).contains("pane.close"))
	}

	func testUnreachableMachinesUnknownMachinesAndBadIDsAreErrors() async throws {
		let dead = try await phone.call("DELETE", "/v1/agents/m_fake-dead.w1%3Ap1")
		XCTAssertEqual(dead.status, 503)
		let unknown = try await phone.call("DELETE", "/v1/agents/m_nosuch.w1%3Ap1")
		XCTAssertEqual(unknown.status, 404)
		XCTAssertEqual(unknown.errorCode, "not_found")
		let tmux = try await phone.call("DELETE", "/v1/agents/tmux%3Awork")
		XCTAssertEqual(tmux.status, 400)
		let dashed = try await phone.call("DELETE", "/v1/agents/m_fake-main.-w9%3Ap1")
		XCTAssertEqual(dashed.status, 400)
		XCTAssertFalse(rig.cliInvocations().contains { $0.contains("close") })
	}
}
