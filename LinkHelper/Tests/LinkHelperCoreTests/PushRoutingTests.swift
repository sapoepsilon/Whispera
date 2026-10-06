import CryptoKit
import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Approval push routing and content (step 12, contract §3).
final class PushRoutingTests: XCTestCase {
	/// What a `RelayPush` asked the backend, with when.
	final class NotifyLog: @unchecked Sendable {
		struct Call: Equatable {
			var device: String
			var kind: NotifyKind?
			var requestID: String?
			var sealed: String?
			var at: Date
		}

		private let lock = NSLock()
		private var calls: [Call] = []
		var results: [String: String] = [:]

		func record(_ device: String, _ kind: NotifyKind?, _ requestID: String?, _ sealed: String?) -> String {
			lock.lock()
			defer { lock.unlock() }
			calls.append(Call(device: device, kind: kind, requestID: requestID, sealed: sealed, at: Date()))
			return results[device] ?? "sent"
		}

		var all: [Call] {
			lock.lock()
			defer { lock.unlock() }
			return calls
		}

		func approvals() -> [Call] { all.filter { $0.kind == .approval } }
		func resolved() -> [Call] { all.filter { $0.kind == .approvalResolved } }
	}

	final class Flag: @unchecked Sendable {
		private let lock = NSLock()
		private var stored: Bool
		init(_ value: Bool) { stored = value }
		var value: Bool {
			get {
				lock.lock()
				defer { lock.unlock() }
				return stored
			}
			set {
				lock.lock()
				stored = newValue
				lock.unlock()
			}
		}
	}

	static func record(_ id: String, createdAt: Int, origin: DeviceRecord.Origin = .account, revoked: Bool = false)
		-> DeviceRecord
	{
		var record = DeviceRecord(
			deviceID: id, name: id, link: SoftwareSigningKey().publicKey, approve: SoftwareSigningKey().publicKey,
			sttKeySHA256: "", apns: nil, app: nil, now: createdAt, origin: origin)
		if revoked { record.revokedAt = createdAt + 1 }
		return record
	}

	let older = PushRoutingTests.record("dev_aaaaaaaaaaaaaaaaaaaaaaaa", createdAt: 100)
	let newer = PushRoutingTests.record("dev_bbbbbbbbbbbbbbbbbbbbbbbb", createdAt: 200)
	let third = PushRoutingTests.record("dev_cccccccccccccccccccccccc", createdAt: 150)
	let coded = PushRoutingTests.record("dev_dddddddddddddddddddddddd", createdAt: 300, origin: .code)
	let gone = PushRoutingTests.record("dev_eeeeeeeeeeeeeeeeeeeeeeee", createdAt: 400, revoked: true)

	func testPreferDeviceThenLastDeviceThenMostRecentlyPaired() {
		let all = [older, newer, third, coded, gone]
		let byPrefer = RelayPush.plan(all, preferDevice: older.deviceID, lastDevice: third.deviceID)
		XCTAssertEqual(byPrefer.preferred?.deviceID, older.deviceID)
		XCTAssertEqual(byPrefer.others.map(\.deviceID), [newer.deviceID, third.deviceID])

		let byLast = RelayPush.plan(all, preferDevice: nil, lastDevice: third.deviceID)
		XCTAssertEqual(byLast.preferred?.deviceID, third.deviceID)

		let byRecent = RelayPush.plan(all, preferDevice: nil, lastDevice: nil)
		XCTAssertEqual(byRecent.preferred?.deviceID, newer.deviceID, "code-paired and revoked devices are not pushed")

		for unusable in [coded.deviceID, gone.deviceID, "dev_zzzzzzzzzzzzzzzzzzzzzzzz"] {
			let plan = RelayPush.plan(all, preferDevice: unusable, lastDevice: older.deviceID)
			XCTAssertNil(plan.preferred, unusable)
			XCTAssertEqual(plan.others.count, 3, "an unusable preferred device sends everyone at once")
		}
	}

	private func push(_ id: String = LinkCrypto.newPrefixedID("apr"), prefer: String? = nil) -> ApprovalPush {
		ApprovalPush(
			requestID: id, expiresAt: Int(Date().timeIntervalSince1970) + 300, preferDevice: prefer,
			requester: "agent", key: "API_KEY", summary: "save API_KEY", project: "demo")
	}

	private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
	}

	func testOthersArePushedAfterTheFallbackOnlyWhileStillPending() async throws {
		let log = NotifyLog()
		let relay = RelayPush(notify: { log.record($0, $1, $2, $3) }, fallbackAfter: 0.6)
		let pending = Flag(true)
		let started = Date()
		let request = push(prefer: older.deviceID)
		let ack = relay.notifyApproval(request, devices: [older, newer, third], isPending: { pending.value })
		XCTAssertEqual(ack, "sent")
		try await wait { log.approvals().count == 3 }
		let calls = log.approvals()
		XCTAssertEqual(calls.map(\.device), [older.deviceID, newer.deviceID, third.deviceID])
		XCTAssertLessThan(calls[0].at.timeIntervalSince(started), 0.4)
		XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(started), 0.6)

		// Resolved before the fallback: only the preferred phone was woken, and only it is cleared.
		let second = push(prefer: newer.deviceID)
		_ = relay.notifyApproval(second, devices: [older, newer, third]) { pending.value }
		try await wait { log.approvals().filter { $0.requestID == second.requestID }.count == 1 }
		pending.value = false
		relay.notifyResolved(requestID: second.requestID)
		try await Task.sleep(nanoseconds: 900_000_000)
		XCTAssertEqual(log.approvals().filter { $0.requestID == second.requestID }.map(\.device), [newer.deviceID])
		XCTAssertEqual(log.resolved().filter { $0.requestID == second.requestID }.map(\.device), [newer.deviceID])
	}

	func testAPreferredPushThatDidNotGoOutFallsBackAtOnce() async throws {
		let log = NotifyLog()
		log.results[older.deviceID] = "no_token"
		let relay = RelayPush(notify: { log.record($0, $1, $2, $3) }, fallbackAfter: 30)
		let started = Date()
		_ = relay.notifyApproval(push(prefer: older.deviceID), devices: [older, newer, third]) { true }
		try await wait { log.approvals().count == 3 }
		XCTAssertEqual(log.approvals().count, 3)
		XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no 30 s wait after no_token")

		let unknown = NotifyLog()
		let relay2 = RelayPush(notify: { unknown.record($0, $1, $2, $3) }, fallbackAfter: 30)
		_ = relay2.notifyApproval(push(prefer: coded.deviceID), devices: [older, newer, coded]) { true }
		try await wait { unknown.approvals().count == 2 }
		XCTAssertEqual(Set(unknown.approvals().map(\.device)), [older.deviceID, newer.deviceID])
		let nobody = relay2.notifyApproval(push(), devices: [coded, gone], isPending: { true })
		XCTAssertEqual(nobody, "no_token")
	}

	func testResolvedGoesToEveryDeviceThatWasPushed() async throws {
		let log = NotifyLog()
		log.results[third.deviceID] = "failed"
		let relay = RelayPush(notify: { log.record($0, $1, $2, $3) }, fallbackAfter: 0.1)
		let request = push(prefer: older.deviceID)
		_ = relay.notifyApproval(request, devices: [older, newer, third]) { true }
		try await wait { log.approvals().count == 3 }
		relay.notifyResolved(requestID: request.requestID)
		relay.notifyResolved(requestID: request.requestID)
		try await wait { log.resolved().count == 2 }
		try await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(Set(log.resolved().map(\.device)), [older.deviceID, newer.deviceID], "once each, sent pushes only")
		XCTAssertTrue(log.resolved().allSatisfy { $0.requestID == request.requestID && $0.sealed == nil })
	}

	func testTheSealerNeedsBothAgreementKeys() throws {
		let mac = SoftwareAgreementKey()
		let phone = SoftwareAgreementKey()
		let sealer = PushSealer()
		let request = push()
		XCTAssertNil(sealer.seal(request, phoneID: older.deviceID))
		sealer.configure(macID: "dev_macmacmacmacmacmacmacmac", agreementKey: mac, macName: "Test Mac")
		XCTAssertNil(sealer.seal(request, phoneID: older.deviceID), "a phone without a KEM key gets a generic push")
	}
}

/// Push routing and WLP1 content end to end: helper, broker and account backend.
final class PushDeliveryTests: XCTestCase {
	var backend: FakeAccountBackend!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
			config.approvalFallback = 0.3
		}
	}

	override func tearDown() {
		helper.stop()
	}

	private func soft(_ phone: AccountPhone) -> SoftPhone {
		let soft = SoftPhone(baseURL: helper.baseURL, linkKey: phone.linkKey, approveKey: phone.approveKey)
		soft.deviceID = phone.deviceID
		return soft
	}

	private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
	}

	private func confirm(_ phones: AccountPhone...) async throws {
		let id = await helper.daemon.account.deviceID
		let macID = try XCTUnwrap(id)
		for phone in phones {
			_ = try await helper.daemon.account.confirmApprove(
				phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		}
	}

	func testNamedPushesAreSealedForThePhoneAndGenericOnesCarryNothing() async throws {
		let named = AccountPhone(backend: backend)
		try await named.register(bearer: "tok-alice", name: "Named")
		let generic = AccountPhone(backend: backend)
		try await generic.register(bearer: "tok-alice", name: "Generic")
		let status = try await helper.daemon.account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await helper.daemon.account.syncNow()
		try await confirm(named, generic)

		let set = try await soft(generic).call("PUT", "/v1/devices/me/push", json: ["text": "generic"])
		XCTAssertEqual(set.status, 200)
		XCTAssertEqual(set.json["push_text"] as? String, "generic")
		XCTAssertEqual((set.json["device"] as? [String: Any])?["push_text"] as? String, "generic")
		XCTAssertEqual(helper.daemon.devices.get(generic.deviceID)?.pushText, .generic)
		XCTAssertNil(helper.daemon.lastDevice.current, "setting the push text is background traffic")
		let bad = try await soft(generic).call("PUT", "/v1/devices/me/push", json: ["text": "loud"])
		XCTAssertEqual(bad.errorCode, "bad_request")

		let broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		defer { broker.close() }
		let approval = try broker.request()
		try await wait { self.backend.notifyCalls.filter { $0.kind == "approval" }.count == 2 }
		let pushes = backend.notifyCalls.filter { $0.kind == "approval" }
		XCTAssertEqual(Set(pushes.map(\.device_id)), [named.deviceID, generic.deviceID])
		XCTAssertTrue(pushes.allSatisfy { $0.request_id == approval.id })

		let genericPush = try XCTUnwrap(pushes.first { $0.device_id == generic.deviceID })
		XCTAssertNil(genericPush.sealed)
		let namedPush = try XCTUnwrap(pushes.first { $0.device_id == named.deviceID })
		let sealed = try XCTUnwrap(namedPush.sealed)
		// The phone's side: its own agreement key and the Mac's published one.
		let macKey = try XCTUnwrap(try backend.device(macID)?.verifiedAgreementKey())
		let key = try PushSealing.deriveKey(
			agreementKey: named.agreementKey, peerKey: macKey, phoneID: named.deviceID, macID: macID)
		let payload = try PushSealing.open(sealed, requestID: approval.id, key: key)
		XCTAssertEqual(payload.title, "agent wants API_KEY")
		XCTAssertEqual(payload.body, "save API_KEY · demo · on Test Mac")
		XCTAssertThrowsError(try PushSealing.open(sealed, requestID: LinkCrypto.newPrefixedID("apr"), key: key))

		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("order=1 kind=approval"))
		XCTAssertTrue(log.contains("order=2 kind=approval"))
		XCTAssertTrue(log.contains("text=named"))
		XCTAssertTrue(log.contains("text=generic"))
		XCTAssertFalse(log.contains("API_KEY · demo"), "push text never reaches the log")

		// Denying resolves the approval: both phones get approval.resolved.
		let denied = try await soft(named).call("POST", "/v1/approvals/\(approval.id)/decision", json: [
			"decision": "deny", "signature": try approval.denial(named.approveKey),
		])
		XCTAssertEqual(denied.status, 200)
		try await wait { self.backend.notifyCalls.filter { $0.kind == "approval.resolved" }.count == 2 }
		let resolved = backend.notifyCalls.filter { $0.kind == "approval.resolved" }
		XCTAssertEqual(Set(resolved.map(\.device_id)), [named.deviceID, generic.deviceID])
		XCTAssertTrue(resolved.allSatisfy { $0.request_id == approval.id && $0.sealed == nil })
	}

	func testTheLastDeviceIsPushedFirstAndTheOtherAfterTheFallback() async throws {
		let first = AccountPhone(backend: backend)
		try await first.register(bearer: "tok-alice", name: "First")
		let second = AccountPhone(backend: backend)
		try await second.register(bearer: "tok-alice", name: "Second")
		_ = try await helper.daemon.account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		_ = try await helper.daemon.account.syncNow()
		try await confirm(first, second)

		let me = try await soft(first).call("GET", "/v1/devices/me")
		XCTAssertEqual(me.status, 200)
		_ = try await soft(second).call("PUT", "/v1/devices/me/apns", json: ["token": String(repeating: "a", count: 64)])
		XCTAssertEqual(helper.daemon.lastDevice.current, first.deviceID, "apns updates do not count as use")

		let broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		defer { broker.close() }
		_ = try broker.request()
		try await wait { self.backend.notifyCalls.count == 2 }
		XCTAssertEqual(backend.notifyCalls.map(\.device_id), [first.deviceID, second.deviceID])
	}
}
