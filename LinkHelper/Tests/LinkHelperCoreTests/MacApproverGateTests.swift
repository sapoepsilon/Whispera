import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore
@testable import LinkHelperXPC

/// Who may settle an approval. A phone decides through the device registry, which must say the
/// owner confirmed it, both to approve and to deny. The Mac approval card decides with its own
/// key and never through the registry, so an account device that shares its id can neither block
/// nor impersonate it; its deny is signed and verified like its approve.
final class MacApproverGateTests: XCTestCase {
	var helper: TestDaemon!
	var broker: FakeBroker!
	let macKey = SoftwareSigningKey()
	let macID = MacApproveKey.newDeviceID()

	override func setUpWithError() throws {
		helper = try TestDaemon()
		broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
	}

	override func tearDown() {
		broker?.close()
		helper?.stop()
	}

	private var approvals: ApprovalsServer { helper.daemon.approvals }

	private func enrollMac() throws {
		let identity = MacApproveKey.Identity(
			deviceID: macID, keyBlob: Data(), publicKeyX963: macKey.publicKey.x963, createdAt: 0)
		let reply = helper.daemon.enrollMacApproverJSON(MacApproveKey.enrollment(identity, name: "Test Mac"))
		let approver = try XCTUnwrap(WireJSON.decodeObject(reply)?["mac_approver"] as? [String: Any])
		XCTAssertEqual(approver["device_id"] as? String, macID)
	}

	/// Pins an account device as an account sync would: unconfirmed.
	@discardableResult
	private func pinAccountDevice(_ id: String, approve: SoftwareSigningKey) throws -> DeviceRecord {
		try helper.daemon.devices.pinAccountDevice(
			deviceID: id, name: "Planted iPhone", link: SoftwareSigningKey().publicKey, approve: approve.publicKey,
			kem: SoftwareAgreementKey().publicKey
		).record
	}

	private func code(_ body: () throws -> [String: Any]) -> (Int, String)? {
		do {
			_ = try body()
			return nil
		} catch let error as APIError {
			return (error.status, error.code)
		} catch {
			XCTFail("unexpected \(error)")
			return nil
		}
	}

	// MARK: Phones: the registry decides

	func testAnUnconfirmedAccountDeviceGets403OnApproveAndDeny() throws {
		let key = SoftwareSigningKey()
		let record = try pinAccountDevice(MacApproveKey.newDeviceID(), approve: key)
		XCTAssertFalse(record.approveConfirmed)
		let approval = try broker.request()

		let approve = code { try approvals.decide(approval.id, device: record, decision: "approve", signature: try approval.signature(key)) }
		XCTAssertEqual(approve?.0, 403)
		XCTAssertEqual(approve?.1, "device_unconfirmed")
		let deny = code { try approvals.decide(approval.id, device: record, decision: "deny", signature: try approval.denial(key)) }
		XCTAssertEqual(deny?.0, 403)
		XCTAssertEqual(deny?.1, "device_unconfirmed")

		// A caller's copy that claims confirmation does not count: the registry is re-read.
		var forged = record
		forged.approveConfirmed = true
		let forgedApprove = code {
			try approvals.decide(approval.id, device: forged, decision: "approve", signature: try approval.signature(key))
		}
		XCTAssertEqual(forgedApprove?.1, "device_unconfirmed")
		XCTAssertEqual(broker.decisions.count, 0, "nothing reached the broker")
		XCTAssertEqual(try approvals.get(approval.id)["status"] as? String, "pending")
	}

	func testARevokedDeviceGets403Too() throws {
		let key = SoftwareSigningKey()
		let record = try pinAccountDevice(MacApproveKey.newDeviceID(), approve: key)
		_ = try helper.daemon.devices.confirmApprove(record.deviceID)
		_ = helper.daemon.devices.revoke(record.deviceID)
		let approval = try broker.request()
		let refused = code {
			try approvals.decide(approval.id, device: record, decision: "approve", signature: try approval.signature(key))
		}
		XCTAssertEqual(refused?.1, "device_unconfirmed")
	}

	// MARK: The Mac card: its own key, never the registry

	func testTheMacCardIsNotBlockedByAnUnconfirmedAccountDeviceWithItsID() throws {
		try enrollMac()
		let planted = SoftwareSigningKey()
		try pinAccountDevice(macID, approve: planted)
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(macID)).approveConfirmed)
		let approval = try broker.request()

		// The planted key cannot pass for the Mac...
		let impostor = code {
			try approvals.decideFromMac(approval.id, decision: "approve", signature: try approval.signature(planted))
		}
		XCTAssertEqual(impostor?.0, 422)
		XCTAssertEqual(impostor?.1, "bad_signature")
		// ...and does not stop it.
		let signature = try approval.signature(macKey)
		let reply = try approvals.decideFromMac(approval.id, decision: "approve", signature: signature)
		XCTAssertEqual(reply["status"] as? String, "approved")
		XCTAssertEqual(broker.decisions.count, 1)
		XCTAssertEqual(broker.decisions.last?["device_id"] as? String, macID)
		XCTAssertEqual(broker.decisions.last?["signature"] as? String, signature)
	}

	func testTheMacCardIsNotBlockedByARevokedAccountDeviceWithItsID() throws {
		try enrollMac()
		try pinAccountDevice(macID, approve: SoftwareSigningKey())
		_ = try helper.daemon.devices.confirmApprove(macID)
		XCTAssertNotNil(helper.daemon.devices.revoke(macID))
		let approval = try broker.request()
		let denial = try approval.denial(macKey)
		let reply = try approvals.decideFromMac(approval.id, decision: "deny", signature: denial)
		XCTAssertEqual(reply["status"] as? String, "denied")
		XCTAssertEqual(broker.decisions.last?["signature"] as? String, denial)
	}

	func testTheMacDenyMustBeSignedWithTheMacKeyOverWL1Deny() throws {
		try enrollMac()
		let approval = try broker.request()
		for (label, signature) in [
			("unsigned", nil as String?), ("empty", ""), ("approve signature", try approval.signature(macKey)),
			("another key", try approval.denial(SoftwareSigningKey())), ("not base64", "!!"),
		] {
			let refused = code { try approvals.decideFromMac(approval.id, decision: "deny", signature: signature) }
			XCTAssertEqual(refused?.0, 422, label)
			XCTAssertEqual(refused?.1, "bad_signature", label)
		}
		XCTAssertEqual(broker.decisions.count, 0, "no unsigned or mis-signed deny reached the broker")
		let reply = try approvals.decideFromMac(approval.id, decision: "deny", signature: try approval.denial(macKey))
		XCTAssertEqual(reply["status"] as? String, "denied")
	}

	func testTheMacApproveIsVerifiedEvenWhenThePhonePrecheckIsOff() throws {
		helper.stop()
		broker.close()
		helper = try TestDaemon { $0.testSkipApprovePrecheck = true }
		broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		try enrollMac()
		let approval = try broker.request()
		let refused = code {
			try approvals.decideFromMac(approval.id, decision: "approve", signature: try approval.denial(macKey))
		}
		XCTAssertEqual(refused?.1, "bad_signature")
	}

	func testWithoutAMacApproverTheCardIsRefused() throws {
		let approval = try broker.request()
		let refused = code {
			try approvals.decideFromMac(approval.id, decision: "approve", signature: try approval.signature(macKey))
		}
		XCTAssertEqual(refused?.0, 409)
		XCTAssertEqual(refused?.1, "no_mac_approver")
	}

	func testTheMacApproverIsConfirmedExplicitly() throws {
		let approver = MacApprover(deviceID: macID, name: "Mac", approvePubkey: macKey.publicKey.x963Base64, createdAt: 1)
		let record = try XCTUnwrap(approver.deviceRecord)
		XCTAssertTrue(record.approveConfirmed)
		XCTAssertEqual(record.approvePubkey, macKey.publicKey.x963Base64)
		XCTAssertNil(helper.daemon.devices.get(macID), "enrolling never adds the Mac to the device registry")
		try enrollMac()
		XCTAssertNil(helper.daemon.devices.get(macID))
	}
}
