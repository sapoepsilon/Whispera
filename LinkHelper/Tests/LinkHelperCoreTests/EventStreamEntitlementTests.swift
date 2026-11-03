import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// An open `/v1/events` stream must not outlive its device's right to it: a revoke, a return to
/// unconfirmed, or keys swapped behind the device id end it.
final class EventStreamEntitlementTests: XCTestCase {
	private func record(link: SoftwareSigningKey, approve: SoftwareSigningKey, confirmed: Bool = true) -> DeviceRecord {
		DeviceRecord(
			deviceID: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", name: "iPhone", link: link.publicKey, approve: approve.publicKey,
			sttKeySHA256: "", apns: nil, app: nil, now: 1, approveConfirmed: confirmed, origin: .account)
	}

	func testStreamEndsWhenTheDeviceLosesConfirmationOrKeys() {
		let link = SoftwareSigningKey(), approve = SoftwareSigningKey()
		let opened = record(link: link, approve: approve)
		XCTAssertTrue(LinkAPI.mayKeepStreaming(opened, opened: opened))
		XCTAssertFalse(LinkAPI.mayKeepStreaming(nil, opened: opened))
		XCTAssertFalse(LinkAPI.mayKeepStreaming(record(link: link, approve: approve, confirmed: false), opened: opened))
		var revoked = opened
		revoked.revokedAt = 2
		XCTAssertFalse(LinkAPI.mayKeepStreaming(revoked, opened: opened))
		XCTAssertFalse(LinkAPI.mayKeepStreaming(record(link: SoftwareSigningKey(), approve: approve), opened: opened))
		XCTAssertFalse(LinkAPI.mayKeepStreaming(record(link: link, approve: SoftwareSigningKey()), opened: opened))
	}
}
