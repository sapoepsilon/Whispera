import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// `devices.revoke` of an account phone reaches the account: the backend revokes it (so the
/// relay and the account's other Macs drop it) and this Mac withdraws its vouch at once. The
/// local revoke stands when the backend cannot be reached, and the backend call is retried
/// with the next bearer. A peer Mac drops the phone only on a successful listing without it.
final class AccountRevokeTests: XCTestCase {
	var backend: FakeAccountBackend!
	var trusted: TestDaemon!
	var peer: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		trusted = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Trusted Mac"
		}
		peer = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Peer Mac"
		}
	}

	override func tearDown() {
		trusted.stop()
		peer.stop()
	}

	private func join(_ helper: TestDaemon) async throws -> String {
		let status = try await helper.daemon.account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		return try XCTUnwrap(status["device_id"] as? String)
	}

	private func admin(_ helper: TestDaemon, _ request: [String: Any]) throws -> [String: Any] {
		let connection = try UnixConnection.connect(path: helper.daemon.config.paths.adminSocket, timeout: 2)
		defer { connection.close() }
		try connection.sendLine(request)
		guard case .line(let line) = try connection.readLine(timeout: 30) else { return [:] }
		return WireJSON.decodeObject(line) ?? [:]
	}

	/// The phone is confirmed by its safety number on both Macs, so the trusted Mac vouches for it.
	private func scene() async throws -> AccountPhone {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: "Sam's iPhone")
		let trustedID = try await join(trusted)
		let peerID = try await join(peer)
		for (helper, _) in [(trusted!, trustedID), (peer!, peerID)] {
			_ = try await helper.daemon.account.syncNow()
			_ = try await helper.daemon.account.confirmApprove(
				phone.deviceID, safetyNumber: try await phone.safetyNumber(with: helper.daemon.account))
			_ = try await helper.daemon.account.syncNow()
		}
		XCTAssertTrue(trusted.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID })
		XCTAssertEqual(peer.daemon.devices.get(phone.deviceID)?.approveConfirmed, true)
		return phone
	}

	func testRevokingAnAccountPhoneRevokesItOnTheBackendAndWithdrawsTheVouch() async throws {
		let phone = try await scene()
		let reply = try admin(trusted, ["op": "devices.revoke", "device_id": phone.deviceID, "bearer": "tok-alice"])
		XCTAssertEqual(reply["ok"] as? Bool, true)
		XCTAssertEqual((reply["account_revoke"] as? [String: Any])?["ok"] as? Bool, true)
		XCTAssertEqual(backend.revokeCalls, [phone.deviceID])
		XCTAssertTrue(try XCTUnwrap(backend.device(phone.deviceID)).isRevoked)
		XCTAssertTrue(try XCTUnwrap(trusted.daemon.devices.get(phone.deviceID)).isRevoked)
		XCTAssertFalse(trusted.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID })
		_ = try await trusted.daemon.account.syncNow()
		XCTAssertFalse(
			trusted.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID },
			"a sync does not re-sign it")

		// The peer Mac drops its confirmation on its next successful listing.
		let report = try await peer.daemon.account.syncNow()
		XCTAssertEqual(report.dropped, [phone.deviceID])
		XCTAssertTrue(try XCTUnwrap(peer.daemon.devices.get(phone.deviceID)).isRevoked)
	}

	func testACodePairedDeviceIsRevokedLocallyOnly() async throws {
		_ = try await join(trusted)
		let begin = trusted.daemon.pairing.begin(ttl: 60)
		let code = (begin["code"] as! String).replacingOccurrences(of: "-", with: "")
		let phone = SoftPhone(baseURL: trusted.baseURL)
		let paired = try await phone.pair(code: code, daemonFP: trusted.daemon.daemonFP)
		XCTAssertEqual(paired.status, 201)
		let reply = try admin(trusted, ["op": "devices.revoke", "device_id": phone.deviceID, "bearer": "tok-alice"])
		XCTAssertEqual(reply["ok"] as? Bool, true)
		XCTAssertNil(reply["account_revoke"])
		XCTAssertEqual(backend.revokeCalls, [])
		XCTAssertTrue(try XCTUnwrap(trusted.daemon.devices.get(phone.deviceID)).isRevoked)
	}

	func testABackendFailureStillRevokesLocallyAndRetriesWithTheNextBearer() async throws {
		let phone = try await scene()
		backend.setFailRevokes(true)
		let reply = try admin(trusted, ["op": "devices.revoke", "device_id": phone.deviceID, "bearer": "tok-alice"])
		XCTAssertEqual(reply["ok"] as? Bool, true)
		let outcome = try XCTUnwrap(reply["account_revoke"] as? [String: Any])
		XCTAssertEqual(outcome["ok"] as? Bool, false)
		XCTAssertEqual(outcome["queued"] as? Bool, true)
		XCTAssertNotNil((outcome["error"] as? [String: Any])?["code"] as? String)
		XCTAssertTrue(try XCTUnwrap(trusted.daemon.devices.get(phone.deviceID)).isRevoked)
		XCTAssertFalse(try XCTUnwrap(backend.device(phone.deviceID)).isRevoked)
		XCTAssertFalse(trusted.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID })
		let answer = try await SoftPhone(baseURL: trusted.baseURL, linkKey: phone.linkKey, approveKey: phone.approveKey)
			.withDevice(phone.deviceID).call("GET", "/v1/devices/me")
		XCTAssertEqual(answer.errorCode, "auth_revoked")

		// The app hands the helper a bearer again: the queued revoke goes through.
		backend.setFailRevokes(false)
		_ = try await join(trusted)
		XCTAssertTrue(try XCTUnwrap(backend.device(phone.deviceID)).isRevoked)
		XCTAssertEqual(backend.revokeCalls, [phone.deviceID, phone.deviceID])
	}

	func testWithoutABearerTheBackendRevokeIsQueued() async throws {
		let phone = try await scene()
		let reply = try admin(trusted, ["op": "devices.revoke", "device_id": phone.deviceID])
		let outcome = try XCTUnwrap(reply["account_revoke"] as? [String: Any])
		XCTAssertEqual((outcome["error"] as? [String: Any])?["code"] as? String, "bearer_required")
		XCTAssertEqual(outcome["queued"] as? Bool, true)
		XCTAssertEqual(backend.revokeCalls, [])
		_ = try await join(trusted)
		XCTAssertTrue(try XCTUnwrap(backend.device(phone.deviceID)).isRevoked)
	}

	func testAFailedListingDoesNotDropAConfirmedPhone() async throws {
		let phone = try await scene()
		backend.revoke(phone.deviceID)
		backend.setFailPeers(true)
		do {
			_ = try await peer.daemon.account.syncNow()
			XCTFail("the listing failed")
		} catch {}
		XCTAssertEqual(peer.daemon.devices.get(phone.deviceID)?.isRevoked, false)
		XCTAssertEqual(peer.daemon.devices.get(phone.deviceID)?.approveConfirmed, true)

		backend.setFailPeers(false)
		let report = try await peer.daemon.account.syncNow()
		XCTAssertEqual(report.dropped, [phone.deviceID])
	}

	func testAListingWithoutThePhoneDropsItsConfirmationOnThePeer() async throws {
		let phone = try await scene()
		backend.remove(phone.deviceID)
		let report = try await peer.daemon.account.syncNow()
		XCTAssertEqual(report.dropped, [phone.deviceID])
		XCTAssertTrue(try XCTUnwrap(peer.daemon.devices.get(phone.deviceID)).isRevoked)
	}
}

extension SoftPhone {
	fileprivate func withDevice(_ id: String) -> SoftPhone {
		deviceID = id
		return self
	}
}
