import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// The 5-minute approval window: the helper keeps the approval and the broker connection until
/// `expires_at` (plus grace), so a phone decision late in the window still reaches the broker;
/// after `expires_at` it is refused with the usual error.
final class ApprovalWindowTests: XCTestCase {
	final class Clock: @unchecked Sendable {
		private let lock = NSLock()
		private var value: Int
		init(_ start: Int) { value = start }
		var now: Int {
			get {
				lock.lock()
				defer { lock.unlock() }
				return value
			}
			set {
				lock.lock()
				value = newValue
				lock.unlock()
			}
		}
	}

	var directory: URL!
	var server: ApprovalsServer!
	var broker: FakeBroker!
	var phone: DeviceRecord!
	let approveKey = SoftwareSigningKey()
	let clock = Clock(1_800_000_000)

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("wla-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let registry = try DeviceRegistry(
			path: directory.appendingPathComponent("devices.json").path,
			keysDir: directory.appendingPathComponent("keys").path)
		phone = try registry.add(
			name: "Phone", link: SoftwareSigningKey().publicKey, approve: approveKey.publicKey, sttKeySHA256: "",
			apns: nil, app: nil)
		let clock = self.clock
		server = ApprovalsServer(
			socketPath: directory.appendingPathComponent("a.sock").path, devices: registry, publish: { _, _ in },
			clock: { clock.now })
		try server.start()
		broker = try FakeBroker(socketPath: directory.appendingPathComponent("a.sock").path)
	}

	override func tearDown() {
		broker.close()
		server.stop()
		try? FileManager.default.removeItem(at: directory)
	}

	func testADecisionLateInTheWindowIsAcceptedAndOneAfterExpiryIsRefused() throws {
		let start = clock.now
		let early = try broker.request(now: start, ttl: 300)
		clock.now = start + 65
		let approved = try server.decide(
			early.id, device: phone, decision: "approve", signature: try early.signature(approveKey))
		XCTAssertEqual(approved["status"] as? String, "approved")
		XCTAssertEqual(approved["broker_outcome"] as? String, "accepted")

		let late = try broker.request(now: start + 65, ttl: 300)
		clock.now = start + 65 + 299
		let lastSecond = try server.decide(
			late.id, device: phone, decision: "deny", signature: try late.denial(approveKey))
		XCTAssertEqual(lastSecond["status"] as? String, "denied")

		let expired = try broker.request(now: clock.now, ttl: 300)
		clock.now += 301
		XCTAssertThrowsError(
			try server.decide(expired.id, device: phone, decision: "approve", signature: try expired.signature(approveKey))
		) { error in
			let api = error as? APIError
			XCTAssertEqual(api?.status, 409)
			XCTAssertEqual(api?.code, "approval_not_pending")
			XCTAssertEqual(api?.extra["status"] as? String, "expired")
		}
		XCTAssertEqual(try server.get(expired.id)["status"] as? String, "expired")
	}
}
