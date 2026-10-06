import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Account pairing on the helper (step 11) against an in-memory account backend: a phone of the
/// Mac's account is pinned unconfirmed and gets nothing until the owner confirms its safety
/// number, then it is offered the link; revocation drops it, `unpaired` is honoured and another
/// account's devices never get in.
final class AccountPairingTests: XCTestCase {
	var backend: FakeAccountBackend!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		backend.addAccount("bob", bearer: "tok-bob")
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
		}
	}

	override func tearDown() {
		helper.stop()
	}

	private var account: AccountLink { helper.daemon.account }

	private func joinAccount() async throws -> String {
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		return try XCTUnwrap(status["device_id"] as? String)
	}

	/// The owner confirms `phone` with the safety number the iPhone shows.
	@discardableResult
	private func confirm(_ phone: AccountPhone) async throws -> [String: Any] {
		let id = await account.deviceID
		let macID = try XCTUnwrap(id)
		return try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
	}

	private func offers(_ messages: [LinkMessage]) -> [LinkOffer] {
		messages.compactMap { if case .linkOffer(let offer) = $0 { return offer } else { return nil } }
	}

	/// A soft phone that talks to the helper over HTTP as the account phone.
	private func httpPhone(_ phone: AccountPhone, sttKey: String = "") -> SoftPhone {
		let soft = SoftPhone(baseURL: helper.baseURL, linkKey: phone.linkKey, approveKey: phone.approveKey)
		soft.deviceID = phone.deviceID
		soft.sttKey = sttKey
		return soft
	}

	func testSyncPinsTheAccountPhoneUnconfirmedAndOffersTheLinkOnlyAfterTheOwnerConfirms() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: "Alice's iPhone")
		let macID = try await joinAccount()
		XCTAssertEqual(backend.device(macID)?.platform, .macos)
		XCTAssertEqual(backend.device(macID)?.name, "Test Mac")
		XCTAssertNotNil(try backend.device(macID)?.verifiedAgreementKey(), "the Mac publishes a KEM record")

		let report = try await account.syncNow()
		XCTAssertEqual(report.pinned, [phone.deviceID])
		XCTAssertEqual(report.offered, [], "nothing goes to a phone the owner has not confirmed")
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		XCTAssertEqual(record.origin, .account)
		XCTAssertFalse(record.approveConfirmed)
		XCTAssertEqual(record.sttKeySHA256, "")
		XCTAssertEqual(record.name, "Alice's iPhone")
		XCTAssertEqual(record.approvePubkey, phone.approveKey.publicKey.x963Base64)
		XCTAssertEqual(record.kemPubkey, phone.agreementKey.publicKey.x963Base64)
		let nothingYet = try await phone.receive()
		XCTAssertEqual(nothingYet, [])

		// The card shows the same safety number the iPhone computes from the keys it was given.
		let pending = await account.pendingConfirmations()
		XCTAssertEqual(pending.map { $0["device_id"] as? String }, [phone.deviceID])
		XCTAssertEqual(pending.first?["safety_number"] as? String, try phone.safetyNumber(macID: macID))
		XCTAssertEqual(pending.first?["key_changed"] as? Bool, false)

		let confirmed = try await confirm(phone)
		XCTAssertEqual(confirmed["notified"] as? Bool, true)
		let messages = try await phone.receive()
		XCTAssertEqual(messages.count, 2)
		XCTAssertEqual(messages.last, .approveConfirmed(deviceID: phone.deviceID))
		let offer = try XCTUnwrap(offers(messages).first)
		XCTAssertEqual(offer.helper_device_id, macID)
		XCTAssertEqual(offer.base_urls, ["http://127.0.0.1:\(helper.port)"])
		XCTAssertEqual(offer.stt_base_url, "http://127.0.0.1:\(helper.port)/v1")
		XCTAssertEqual(try offer.verifiedDaemonKey().fingerprint, helper.daemon.daemonFP)
		XCTAssertEqual(offer.mac_name, "Test Mac")
		XCTAssertTrue(offer.approve_confirmed)

		// The offer is enough to talk to the helper: WL1 as the account device id, and its STT key.
		let soft = httpPhone(phone, sttKey: try XCTUnwrap(offer.stt_key))
		let me = try await soft.call("GET", "/v1/devices/me")
		XCTAssertEqual(me.status, 200)
		XCTAssertEqual((me.json["device"] as? [String: Any])?["approve_confirmed"] as? Bool, true)
		var models = URLRequest(url: helper.baseURL.appendingPathComponent("v1/models"))
		models.setValue("Bearer \(soft.sttKey)", forHTTPHeaderField: "Authorization")
		let modelsStatus = try await SoftPhone.send(models).status
		XCTAssertEqual(modelsStatus, 200)

		// Idempotent: nothing new to pin, nothing re-sent, no second registration.
		let sends = backend.sendCount
		let again = try await account.syncNow()
		XCTAssertEqual(again, AccountLink.SyncReport())
		XCTAssertEqual(backend.sendCount, sends)
		let secondRound = try await phone.receive()
		XCTAssertEqual(secondRound, [])
		let registrations = backend.registerCount
		_ = try await joinAccount()
		XCTAssertEqual(backend.registerCount, registrations, "the Mac registers once")
		let none = await account.pendingConfirmations()
		XCTAssertTrue(none.isEmpty)
	}

	func testRevokedOrMissingPhonesAreDroppedAndGetNothing() async throws {
		let kept = AccountPhone(backend: backend)
		try await kept.register(bearer: "tok-alice", name: "Kept")
		let revoked = AccountPhone(backend: backend)
		try await revoked.register(bearer: "tok-alice", name: "Revoked")
		let removed = AccountPhone(backend: backend)
		try await removed.register(bearer: "tok-alice", name: "Removed")
		_ = try await joinAccount()
		_ = try await account.syncNow()
		XCTAssertEqual(helper.daemon.devices.active().count, 3)

		backend.revoke(revoked.deviceID)
		backend.remove(removed.deviceID)
		let sends = backend.sendCount
		let report = try await account.syncNow()
		XCTAssertEqual(Set(report.dropped), [revoked.deviceID, removed.deviceID])
		XCTAssertEqual(backend.sendCount, sends, "nothing is sent to a dropped phone")
		XCTAssertEqual(helper.daemon.devices.active().map(\.deviceID), [kept.deviceID])

		let answer = try await httpPhone(revoked).call("GET", "/v1/devices/me")
		XCTAssertEqual(answer.status, 401)
		XCTAssertEqual(answer.errorCode, "auth_revoked")
		let keptStatus = try await httpPhone(kept).call("GET", "/v1/devices/me").status
		XCTAssertEqual(keptStatus, 200)

		// A revoked id stays revoked here even if a backend listed it again.
		let repinned = try await account.syncNow().pinned
		XCTAssertEqual(repinned, [])
	}

	func testApproveAndDenyWaitForTheOwnersConfirmationAndDenyIsSigned() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		_ = try await joinAccount()
		_ = try await account.syncNow()
		let soft = httpPhone(phone)
		let broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		defer { broker.close() }

		let first = try broker.request()
		XCTAssertEqual(first.ackDevices, 0, "an unconfirmed phone is not counted or pushed")
		let refused = try await soft.call(
			"POST", "/v1/approvals/\(first.id)/decision",
			json: ["decision": "approve", "signature": try first.signature(phone.approveKey)])
		XCTAssertEqual(refused.status, 403)
		XCTAssertEqual(refused.errorCode, "device_unconfirmed")
		let deniedEarly = try await soft.call(
			"POST", "/v1/approvals/\(first.id)/decision",
			json: ["decision": "deny", "signature": try first.denial(phone.approveKey)])
		XCTAssertEqual(deniedEarly.status, 403)
		XCTAssertEqual(deniedEarly.errorCode, "device_unconfirmed")

		try await confirm(phone)
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
		let pending = await account.pendingConfirmations()
		XCTAssertTrue(pending.isEmpty)

		// Deny: unsigned, or signed as an approve, is refused; WL1-DENY over the bytes is not.
		let unsigned = try await soft.call("POST", "/v1/approvals/\(first.id)/decision", json: ["decision": "deny"])
		XCTAssertEqual(unsigned.status, 422)
		XCTAssertEqual(unsigned.errorCode, "bad_signature")
		let approveAsDeny = try await soft.call(
			"POST", "/v1/approvals/\(first.id)/decision",
			json: ["decision": "deny", "signature": try first.signature(phone.approveKey)])
		XCTAssertEqual(approveAsDeny.errorCode, "bad_signature")
		let wrongKey = try await soft.call(
			"POST", "/v1/approvals/\(first.id)/decision",
			json: ["decision": "deny", "signature": try first.denial(phone.linkKey)])
		XCTAssertEqual(wrongKey.errorCode, "bad_signature")
		let denial = try first.denial(phone.approveKey)
		let denied = try await soft.call(
			"POST", "/v1/approvals/\(first.id)/decision", json: ["decision": "deny", "signature": denial])
		XCTAssertEqual(denied.status, 200)
		XCTAssertEqual(denied.json["status"] as? String, "denied")
		XCTAssertEqual(broker.decisions.last?["signature"] as? String, denial, "the broker gets the signed deny")

		let second = try broker.request()
		XCTAssertEqual(second.ackDevices, 1)
		let denyAsApprove = try await soft.call(
			"POST", "/v1/approvals/\(second.id)/decision",
			json: ["decision": "approve", "signature": try second.denial(phone.approveKey)])
		XCTAssertEqual(denyAsApprove.errorCode, "bad_signature")
		let approved = try await soft.call(
			"POST", "/v1/approvals/\(second.id)/decision",
			json: ["decision": "approve", "signature": try second.signature(phone.approveKey)])
		XCTAssertEqual(approved.status, 200)
		XCTAssertEqual(approved.json["status"] as? String, "approved")
		XCTAssertEqual(approved.json["broker_outcome"] as? String, "accepted")

		// The confirmation survives a sync.
		_ = try await account.syncNow()
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
	}

	func testUnpairedFromThePhoneRevokesItsPinForGood() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		let macID = try await joinAccount()
		_ = try await account.syncNow()
		_ = try await phone.receive()

		try await phone.send(.unpaired(deviceID: phone.deviceID), toDevice: macID)
		let report = try await account.syncNow()
		XCTAssertEqual(report.offered, [])
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).isRevoked)
		let afterUnpaired = try await httpPhone(phone).call("GET", "/v1/devices/me").errorCode
		XCTAssertEqual(afterUnpaired, "auth_revoked")

		let later = try await account.syncNow()
		XCTAssertEqual(later.pinned, [])
		XCTAssertEqual(later.offered, [])
		let laterMessages = try await phone.receive()
		XCTAssertEqual(laterMessages, [])
	}

	func testAnotherAccountsDevicesNeverAppearAndCannotUnpairOurs() async throws {
		let alicePhone = AccountPhone(backend: backend)
		try await alicePhone.register(bearer: "tok-alice")
		let bobPhone = AccountPhone(backend: backend)
		try await bobPhone.register(bearer: "tok-bob", name: "Bob's iPhone")
		let macID = try await joinAccount()
		let report = try await account.syncNow()
		XCTAssertEqual(report.pinned, [alicePhone.deviceID])
		XCTAssertNil(helper.daemon.devices.get(bobPhone.deviceID))
		let bobMessages = try await bobPhone.receive()
		XCTAssertEqual(bobMessages, [], "bob gets no offer")
		let bobSeesMac = try await bobPhone.relay.peers().contains { $0.device_id == macID }
		XCTAssertFalse(bobSeesMac)

		// The relay refuses bob → mac; a forged envelope slipped into the queue is not acted on.
		let mac = try XCTUnwrap(backend.device(macID))
		do {
			_ = try await bobPhone.relay.send(try LinkMessage.unpaired(deviceID: alicePhone.deviceID).encoded(), to: mac)
			XCTFail("cross-account relay send must be refused")
		} catch let error as LinkError {
			XCTAssertEqual(error.status, 403)
		}
		let forged = try SealedEnvelope.seal(
			try LinkMessage.unpaired(deviceID: alicePhone.deviceID).encoded(), from: bobPhone.deviceID,
			signingKey: bobPhone.linkKey, to: macID, recipientKey: try XCTUnwrap(mac.verifiedAgreementKey()),
			now: Int64(Date().timeIntervalSince1970))
		backend.inject(from: bobPhone.deviceID, to: macID, ciphertext: forged.base64)
		_ = try await account.syncNow()
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(alicePhone.deviceID)).isRevoked)
		XCTAssertNil(helper.daemon.devices.get(bobPhone.deviceID))
	}

	func testSigningOutUnpairsTheAccountPhonesButKeepsCodePairedOnes() async throws {
		let coded = try await helper.pairedPhone()
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		_ = try await joinAccount()
		_ = try await account.syncNow()
		_ = try await phone.receive()

		let status = await account.disconnect()
		XCTAssertEqual(status["status"] as? String, "signed_out")
		let afterSignOut = try await phone.receive()
		XCTAssertEqual(afterSignOut, [.unpaired(deviceID: phone.deviceID)])
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).isRevoked)
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(coded.deviceID)).isRevoked)
		XCTAssertFalse(FileManager.default.fileExists(atPath: helper.daemon.config.paths.accountState))
	}

	func testCodePairedAndPreStep11DevicesCountAsConfirmed() async throws {
		let coded = try await helper.pairedPhone()
		let record = try XCTUnwrap(helper.daemon.devices.get(coded.deviceID))
		XCTAssertTrue(record.approveConfirmed)
		XCTAssertEqual(record.origin, .code)

		var legacy = record.storedJSON
		legacy["approve_confirmed"] = nil
		legacy["origin"] = nil
		let migrated = try XCTUnwrap(DeviceRecord(json: legacy))
		XCTAssertTrue(migrated.approveConfirmed)
		XCTAssertEqual(migrated.origin, .code)

		let reloaded = try DeviceRegistry(
			path: helper.daemon.config.paths.devices, keysDir: helper.daemon.config.paths.keysDir)
		XCTAssertTrue(try XCTUnwrap(reloaded.get(coded.deviceID)).approveConfirmed)
	}

	func testStateSurvivesARestartWithoutReRegistering() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		let macID = try await joinAccount()
		_ = try await account.syncNow()
		try await confirm(phone)
		let registrations = backend.registerCount
		let sends = backend.sendCount

		let context = AccountLink.OfferContext(
			baseURLs: ["http://127.0.0.1:\(helper.port)"], daemonPubkeyB64: helper.daemon.daemonPubkeyB64,
			daemonFP: helper.daemon.daemonFP, macName: "Test Mac")
		let restarted = AccountLink(
			paths: helper.daemon.config.paths, devices: helper.daemon.devices, push: SwitchablePush(),
			transport: backend, pollWait: -1, offerContext: { context })
		let id = await restarted.deviceID
		XCTAssertEqual(id, macID)
		let report = try await restarted.syncNow()
		XCTAssertEqual(report.offered, [], "same offer, not re-sent after a restart")
		XCTAssertEqual(backend.registerCount, registrations)
		XCTAssertEqual(backend.sendCount, sends)
	}

	private func admin(_ request: [String: Any]) throws -> [String: Any] {
		let connection = try UnixConnection.connect(path: helper.daemon.config.paths.adminSocket, timeout: 2)
		defer { connection.close() }
		try connection.sendLine(request)
		guard case .line(let line) = try connection.readLine(timeout: 30) else { return [:] }
		return WireJSON.decodeObject(line) ?? [:]
	}

	func testAdminSocketJoinsTheAccountButConfirmsOnlyWithTheTestFlag() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		let joined = try admin([
			"op": "account.set", "bearer": "tok-alice", "backend_url": backend.baseURL.absoluteString,
		])
		XCTAssertEqual(joined["status"] as? String, "registered")
		let synced = try admin(["op": "account.sync"])
		XCTAssertEqual(synced["pinned"] as? [String], [phone.deviceID])
		let pending = try admin(["op": "approve.pending"])
		XCTAssertEqual((pending["devices"] as? [[String: Any]])?.first?["device_id"] as? String, phone.deviceID)

		let refused = try admin([
			"op": "approve.confirm", "device_id": phone.deviceID,
			"safety_number": try phone.safetyNumber(macID: XCTUnwrap(joined["device_id"] as? String)),
		])
		XCTAssertEqual(refused["ok"] as? Bool, false)
		XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "forbidden")
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)

		let missingBearer = try admin(["op": "account.set", "backend_url": backend.baseURL.absoluteString])
		XCTAssertEqual((missingBearer["error"] as? [String: Any])?["code"] as? String, "bad_request")
	}

	func testAdminConfirmWorksWhenTheTestFlagIsSet() async throws {
		helper.stop()
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.testAdminConfirm = true
		}
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		let macID = try await joinAccount()
		_ = try await account.syncNow()
		let wrong = try admin(["op": "approve.confirm", "device_id": phone.deviceID, "safety_number": "0000 0000 0000"])
		XCTAssertEqual((wrong["error"] as? [String: Any])?["code"] as? String, "keys_changed")
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
		let confirmed = try admin([
			"op": "approve.confirm", "device_id": phone.deviceID, "safety_number": try phone.safetyNumber(macID: macID),
		])
		XCTAssertEqual(confirmed["ok"] as? Bool, true)
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
	}
}

/// The broker side of `approvals.sock`: opens approvals and accepts whatever the helper forwards.
final class FakeBroker {
	struct Approval {
		let id: String
		let canonical: Data
		/// `devices` in the helper's `approval.ack`: how many devices hear about it.
		var ackDevices = 0

		func signature(_ key: SoftwareSigningKey) throws -> String {
			try key.sign(LinkCrypto.approvalMessage(canonical: canonical)).base64EncodedString()
		}

		func denial(_ key: SoftwareSigningKey) throws -> String {
			try key.sign(LinkCrypto.denialMessage(canonical: canonical)).base64EncodedString()
		}
	}

	private let socketPath: String
	private let lock = NSLock()
	private var received: [[String: Any]] = []

	/// Every `approval.decision` the helper forwarded, in order.
	var decisions: [[String: Any]] {
		lock.lock()
		defer { lock.unlock() }
		return received
	}
	private var connections: [UnixConnection] = []
	private var readers: [DispatchSemaphore] = []

	init(socketPath: String) throws {
		self.socketPath = socketPath
	}

	/// Opens an approval created at `now` that expires `ttl` seconds later (the broker's
	/// window is 300 s; 120 keeps older tests as they were).
	func request(now: Int = Int(Date().timeIntervalSince1970), ttl: Int = 120) throws -> Approval {
		let connection = try UnixConnection.connect(path: socketPath, timeout: 2)
		connections.append(connection)
		let id = LinkCrypto.newPrefixedID("apr")
		let canonical: [String: Any] = [
			"v": 1, "request_id": id, "nonce": LinkCrypto.makeNonce(), "op": "save", "key": "API_KEY",
			"summary": "save API_KEY", "project": "demo", "token": "tok", "host": "mac", "caller": "agent",
			"via": "cli", "broker": "test", "created_at": now, "expires_at": now + ttl,
		]
		let bytes = try XCTUnwrap(WireJSON.pythonCanonical(canonical))
		try connection.sendLine([
			"op": "approval.request", "v": 1, "request_id": id, "canonical_b64": bytes.base64EncodedString(),
			"expires_at": now + ttl,
		])
		guard case .line(let ack) = try connection.readLine(timeout: 3), let ackObject = WireJSON.decodeObject(ack),
			ackObject["op"] as? String == "approval.ack"
		else { throw NSError(domain: "FakeBroker", code: 1) }
		let done = DispatchSemaphore(value: 0)
		readers.append(done)
		let thread = Thread {
			defer { done.signal() }
			while true {
				guard let result = try? connection.readLine(timeout: 0.2) else { return }
				switch result {
				case .eof: return
				case .timeout: continue
				case .line(let line):
					guard let message = WireJSON.decodeObject(line), message["op"] as? String == "approval.decision"
					else { continue }
					self.lock.lock()
					self.received.append(message)
					self.lock.unlock()
					try? connection.sendLine(["op": "approval.result", "request_id": id, "outcome": "accepted"])
				}
			}
		}
		thread.start()
		return Approval(id: id, canonical: bytes, ackDevices: WireJSON.strictInt(ackObject["devices"]) ?? -1)
	}

	/// Shuts the sockets down and waits for the readers before closing: a reader still polling
	/// a closed fd number could read the next test's socket once the number is reused.
	func close() {
		for connection in connections { shutdown(connection.fd, SHUT_RDWR) }
		for reader in readers { _ = reader.wait(timeout: .now() + 2) }
		readers.removeAll()
		for connection in connections { connection.close() }
	}
}
