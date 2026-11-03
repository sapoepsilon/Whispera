import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// The replay guard on its own: a repeat is dropped, the set survives a restart, stays bounded
/// and forgets an entry only once its envelope could no longer open.
final class RelayReplayGuardTests: XCTestCase {
	private final class Clock: @unchecked Sendable {
		var now: Int64 = 1_800_000_000
	}

	private var directory: URL!
	private let clock = Clock()

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-seen-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
	}

	private var path: String { directory.appendingPathComponent("relay_seen.json").path }

	private func guardian(capacity: Int = RelayReplayGuard.defaultCapacity) -> RelayReplayGuard {
		let clock = self.clock
		return RelayReplayGuard(path: path, capacity: capacity, clock: { clock.now })
	}

	func testADuplicateMessageIDFromTheSameSenderIsDropped() {
		let seen = guardian()
		let id = LinkCrypto.randomBytes(16)
		XCTAssertTrue(seen.firstSeen(sender: "dev_a", messageID: id, createdAt: clock.now))
		XCTAssertFalse(seen.firstSeen(sender: "dev_a", messageID: id, createdAt: clock.now))
		XCTAssertTrue(seen.firstSeen(sender: "dev_b", messageID: id, createdAt: clock.now), "keyed per sender")
		XCTAssertTrue(seen.firstSeen(sender: "dev_a", messageID: Data(), createdAt: 0), "no id, no guard")
	}

	func testTheSetIsPersistedAtomicallyWith0600AndSurvivesARestart() throws {
		let id = LinkCrypto.randomBytes(16)
		let first = guardian()
		XCTAssertTrue(first.firstSeen(sender: "dev_a", messageID: id, createdAt: clock.now))
		first.flush()
		XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
		let restarted = guardian()
		XCTAssertFalse(restarted.firstSeen(sender: "dev_a", messageID: id, createdAt: clock.now))
	}

	func testTheSetIsBoundedAndAnEvictedEnvelopeStaysRefused() {
		let seen = guardian(capacity: 100)
		let start = clock.now
		for index in 0..<250 {
			clock.now += 1
			XCTAssertTrue(seen.firstSeen(sender: "dev_a", messageID: Data("m\(index)".utf8), createdAt: clock.now))
			XCTAssertLessThanOrEqual(seen.count, 100)
		}
		XCTAssertFalse(seen.firstSeen(sender: "dev_a", messageID: Data("m249".utf8), createdAt: clock.now))
		// m0's id was forgotten, but its envelope is below the low-water mark: still refused.
		XCTAssertFalse(seen.firstSeen(sender: "dev_a", messageID: Data("m0".utf8), createdAt: start + 1))
		XCTAssertNotNil(seen.lowWaterMark(of: "dev_a"))
		XCTAssertTrue(seen.firstSeen(sender: "dev_a", messageID: Data("new".utf8), createdAt: clock.now + 1))
	}

	/// The backend can list any number of fake devices: their messages never evict the entries of
	/// a phone the owner confirmed, and they share one bounded pool.
	func testFakeDevicesCannotFlushAConfirmedPhonesEntries() {
		let seen = guardian()
		let real = LinkCrypto.randomBytes(16)
		let createdAt = clock.now
		XCTAssertTrue(seen.firstSeen(sender: "dev_real", messageID: real, createdAt: createdAt, trusted: true))
		for index in 0..<10_000 {
			_ = seen.firstSeen(
				sender: "dev_fake\(index % 500)", messageID: Data("f\(index)".utf8), createdAt: clock.now + Int64(index),
				trusted: false)
		}
		XCTAssertLessThanOrEqual(seen.count - 1, RelayReplayGuard.untrustedTotal)
		XCTAssertEqual(seen.entries(of: "dev_real"), 1)
		XCTAssertFalse(seen.firstSeen(sender: "dev_real", messageID: real, createdAt: createdAt, trusted: true))
		XCTAssertNil(seen.lowWaterMark(of: "dev_real"))
	}

	func testOneUnconfirmedSenderIsCappedOnItsOwn() {
		let seen = guardian()
		for index in 0..<(RelayReplayGuard.untrustedPerSender * 3) {
			_ = seen.firstSeen(
				sender: "dev_x", messageID: Data("x\(index)".utf8), createdAt: clock.now + Int64(index), trusted: false)
		}
		XCTAssertLessThanOrEqual(seen.entries(of: "dev_x"), RelayReplayGuard.untrustedPerSender)
		XCTAssertFalse(
			seen.firstSeen(sender: "dev_x", messageID: Data("x0".utf8), createdAt: clock.now, trusted: false),
			"an evicted envelope is refused by the mark")
	}

	func testMarksAndUnconfirmedEntriesSurviveARestart() {
		let first = guardian(capacity: 10)
		for index in 0..<30 {
			_ = first.firstSeen(sender: "dev_a", messageID: Data("m\(index)".utf8), createdAt: clock.now + Int64(index))
		}
		XCTAssertTrue(first.firstSeen(sender: "dev_u", messageID: Data("u".utf8), createdAt: clock.now, trusted: false))
		first.flush()
		let restarted = guardian(capacity: 10)
		XCTAssertEqual(restarted.lowWaterMark(of: "dev_a"), first.lowWaterMark(of: "dev_a"))
		XCTAssertFalse(restarted.firstSeen(sender: "dev_u", messageID: Data("u".utf8), createdAt: clock.now, trusted: false))
	}

	func testAnEntryExpiresOnlyAfterTheEnvelopeMaxAge() {
		let seen = guardian()
		let id = LinkCrypto.randomBytes(16)
		let created = clock.now
		XCTAssertTrue(seen.firstSeen(sender: "dev_a", messageID: id, createdAt: created))
		clock.now = created + SealedEnvelope.defaultMaxAge
		XCTAssertFalse(seen.firstSeen(sender: "dev_a", messageID: id, createdAt: created), "still within 7 days")
		clock.now = created + RelayReplayGuard.retention + 1
		seen.flush()
		XCTAssertEqual(seen.count, 0, "gone after 7 days plus the margin")
		XCTAssertGreaterThan(RelayReplayGuard.retention, 7 * 24 * 3600)
	}
}

/// Over the relay: a message the relay delivers again (new seq, same envelope) is handled once,
/// and a replayed `unpaired` from an earlier pairing does not revoke the phone.
final class RelayReplayTests: XCTestCase {
	var backend: FakeAccountBackend!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
		}
	}

	override func tearDown() {
		helper.stop()
	}

	private var account: AccountLink { helper.daemon.account }

	private func pump() async throws { _ = try await account.syncNow() }

	private func pinnedPhone() async throws -> (RelayPhone, AccountPhone) {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try await phone.safetyNumber(with: account))
		_ = try await phone.receive()
		return (RelayPhone(phone, macID: macID), phone)
	}

	func testARedeliveredRequestIsHandledOnce() async throws {
		let (relay, phone) = try await pinnedPhone()
		let request = try relay.request("GET", "/v1/devices/me")
		try await relay.send(request)
		let response = try await relay.response(request.id, pump: pump)
		XCTAssertEqual(response.status, 200)
		let frames = relay.frames(request.id).count

		let original = try XCTUnwrap(backend.sent(to: relay.macID).last)
		backend.inject(from: phone.deviceID, to: relay.macID, ciphertext: original.ciphertext)
		try await pump()
		try await Task.sleep(nanoseconds: 300_000_000)
		try await relay.drain()
		// Without the guard the LinkAPI would answer again (auth_replay) under the same id.
		XCTAssertEqual(relay.frames(request.id).count, frames, "the repeat got no answer")
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("replayed api_request"))
	}

	func testTheSeenSetIsPersistedAfterEachBatch() async throws {
		let (relay, phone) = try await pinnedPhone()
		try await relay.cancel(try relay.request("GET", "/v1/devices/me").id)
		try await pump()
		let cancel = try XCTUnwrap(backend.sent(to: relay.macID).last)
		XCTAssertGreaterThan(account.replayGuard.count, 0)
		XCTAssertTrue(FileManager.default.fileExists(atPath: helper.daemon.config.paths.relaySeen))
		let reloaded = RelayReplayGuard(path: helper.daemon.config.paths.relaySeen)
		let envelope = try SealedEnvelope(base64: cancel.ciphertext)
		XCTAssertFalse(
			reloaded.firstSeen(sender: phone.deviceID, messageID: envelope.messageID, createdAt: envelope.createdAt),
			"persisted after the batch")
	}

	/// An `unpaired` sealed (with the key pinned now) before the phone was pinned here.
	private func staleUnpaired(_ phone: AccountPhone, macID: String, createdAt: Int64) throws -> String {
		let peers = AccountDevices(classifying: backend.devices(ofAccount: "alice"), selfID: phone.deviceID)
		let mac = try XCTUnwrap(peers.peer(macID))
		return try SealedEnvelope.seal(
			try LinkMessage.unpaired(deviceID: phone.deviceID).encoded(), from: phone.deviceID, signingKey: phone.linkKey,
			to: macID, recipientKey: mac.agreementKey, now: createdAt
		).base64
	}

	func testAnUnpairedFromBeforeThisPairingDoesNotRevoke() async throws {
		let (relay, phone) = try await pinnedPhone()
		let pinnedAt = Int64(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).createdAt)
		let old = try staleUnpaired(phone, macID: relay.macID, createdAt: pinnedAt - 3 * 24 * 3600)
		backend.inject(from: phone.deviceID, to: relay.macID, ciphertext: old)
		try await pump()
		XCTAssertEqual(helper.daemon.devices.get(phone.deviceID)?.isRevoked, false)
		XCTAssertEqual(helper.daemon.devices.get(phone.deviceID)?.approveConfirmed, true)
		XCTAssertTrue(try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8).contains("unpaired from an earlier pairing"))

		// A fresh one from the phone still unpairs it.
		try await phone.send(.unpaired(deviceID: phone.deviceID), toDevice: relay.macID)
		try await pump()
		XCTAssertEqual(helper.daemon.devices.get(phone.deviceID)?.isRevoked, true)
	}

	func testAReplayedUnpairedAfterTheKeysChangedDoesNotRevokeTheRepairedPhone() async throws {
		let (relay, phone) = try await pinnedPhone()
		// The phone re-pairs under its id with new keys (a reinstall); the owner confirms again.
		let reinstall = AccountPhone(backend: backend)
		try await reinstall.register(bearer: "tok-alice")
		backend.substituteKeys(of: phone.deviceID, from: reinstall.deviceID)
		let report = try await account.syncNow()
		XCTAssertEqual(report.keyChanged, [phone.deviceID])
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		XCTAssertNotNil(record.keyChangedAt)
		let repinnedAt = Int64(try XCTUnwrap(record.keyChangedAt))

		// An `unpaired` sealed with the new key but before the re-pair (the relay held it).
		let peers = AccountDevices(classifying: backend.devices(ofAccount: "alice"), selfID: phone.deviceID)
		let mac = try XCTUnwrap(peers.peer(relay.macID))
		let stale = try SealedEnvelope.seal(
			try LinkMessage.unpaired(deviceID: phone.deviceID).encoded(), from: phone.deviceID,
			signingKey: reinstall.linkKey, to: relay.macID, recipientKey: mac.agreementKey, now: repinnedAt - 3600
		).base64
		backend.inject(from: phone.deviceID, to: relay.macID, ciphertext: stale)
		try await pump()
		XCTAssertEqual(helper.daemon.devices.get(phone.deviceID)?.isRevoked, false)
		XCTAssertTrue(try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8).contains("unpaired from an earlier pairing"))

		// The old key's `unpaired` does not even open against the keys listed now.
		let oldKey = try staleUnpaired(phone, macID: relay.macID, createdAt: Int64(Date().timeIntervalSince1970))
		backend.inject(from: phone.deviceID, to: relay.macID, ciphertext: oldKey)
		try await pump()
		XCTAssertEqual(helper.daemon.devices.get(phone.deviceID)?.isRevoked, false)
	}
}
