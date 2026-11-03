import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// The safety number is fixed by a commit-then-reveal exchange (`sas_commit`, `sas_nonce`,
/// `sas_reveal`), so a backend that substitutes keys gets one guess at making the two screens
/// agree instead of a 2^20 × 2^20 search. These cover the exchange itself and the helper's side.
final class SafetyNumberCommitmentTests: XCTestCase {
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

	private func listedPhone() async throws -> (AccountPhone, String) {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: "Sam's iPhone")
		let status = try await account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		let macID = try XCTUnwrap(status["device_id"] as? String)
		_ = try await account.syncNow()
		return (phone, macID)
	}

	private func card(_ phone: AccountPhone) async -> [String: Any]? {
		await account.pendingConfirmations().first { $0["device_id"] as? String == phone.deviceID }
	}

	private func expectRefusal(_ code: String, _ phone: AccountPhone, number: String, line: UInt = #line) async {
		do {
			_ = try await account.confirmApprove(phone.deviceID, safetyNumber: number)
			XCTFail("confirmed without a matching committed exchange", line: line)
		} catch let error as APIError {
			XCTAssertEqual(error.status, 409, line: line)
			XCTAssertEqual(error.code, code, line: line)
		} catch {
			XCTFail("\(error)", line: line)
		}
		XCTAssertFalse(helper.daemon.devices.get(phone.deviceID)?.approveConfirmed ?? true, line: line)
	}

	// MARK: The exchange on its own

	private struct Keys {
		let phoneLink = SoftwareSigningKey().publicKey
		let phoneApprove = SoftwareSigningKey().publicKey
		let macLink = SoftwareSigningKey().publicKey
		let phoneID = LinkCrypto.newDeviceID()
		let macID = LinkCrypto.newDeviceID()
	}

	private func reveal(_ keys: Keys, _ responder: inout SASResponder, _ reveal: SASReveal) throws -> String {
		try responder.receive(
			reveal, phoneID: keys.phoneID, macID: keys.macID, macLink: keys.macLink, listedLink: keys.phoneLink,
			listedApprove: keys.phoneApprove)
	}

	func testBothSidesComputeTheSameTwelveDigitsFromACompleteExchange() throws {
		let keys = Keys()
		var phone = SASInitiator(
			phoneID: keys.phoneID, macID: keys.macID, phoneLink: keys.phoneLink, phoneApprove: keys.phoneApprove)
		var mac = try SASResponder(commit: phone.commit, startedAt: 0)
		let revealed = try phone.receive(mac.nonceMessage(macLink: keys.macLink), listedMacLink: keys.macLink)
		let macNumber = try reveal(keys, &mac, revealed)
		XCTAssertEqual(phone.number, macNumber)
		XCTAssertNotNil(macNumber.range(of: "^[0-9]{4} [0-9]{4} [0-9]{4}$", options: .regularExpression))
		XCTAssertEqual(
			mac.number(phoneLink: keys.phoneLink.x963Base64, phoneApprove: keys.phoneApprove.x963Base64, macLink: keys.macLink),
			macNumber)
		XCTAssertNil(
			mac.number(phoneLink: keys.phoneLink.x963Base64, phoneApprove: keys.macLink.x963Base64, macLink: keys.macLink),
			"the number is only for the keys the reveal opened")

		// The nonces are in it: the same keys in a new attempt give another number.
		var again = SASInitiator(
			phoneID: keys.phoneID, macID: keys.macID, phoneLink: keys.phoneLink, phoneApprove: keys.phoneApprove)
		var mac2 = try SASResponder(commit: again.commit, startedAt: 0)
		_ = try reveal(keys, &mac2, try again.receive(mac2.nonceMessage(macLink: keys.macLink), listedMacLink: keys.macLink))
		XCTAssertNotEqual(again.number, phone.number)
	}

	func testARevealThatDoesNotOpenTheCommitmentFailsTheAttemptForGood() throws {
		let keys = Keys()
		var phone = SASInitiator(
			phoneID: keys.phoneID, macID: keys.macID, phoneLink: keys.phoneLink, phoneApprove: keys.phoneApprove)
		var mac = try SASResponder(commit: phone.commit, startedAt: 0)
		let honest = try phone.receive(mac.nonceMessage(macLink: keys.macLink), listedMacLink: keys.macLink)

		// Another nonce under the same commitment (what grinding after seeing the Mac's nonce needs).
		var forged = honest
		forged.phone_nonce = LinkCrypto.randomBytes(SafetyNumber.nonceLength).base64EncodedString()
		XCTAssertThrowsError(try reveal(keys, &mac, forged)) { XCTAssertEqual($0 as? SASError, .commitmentMismatch) }
		XCTAssertEqual(mac.stage, .failed)
		XCTAssertNil(mac.number(phoneLink: keys.phoneLink.x963Base64, phoneApprove: keys.phoneApprove.x963Base64, macLink: keys.macLink))

		// No retry within the attempt, even with the honest reveal.
		XCTAssertThrowsError(try reveal(keys, &mac, honest)) { XCTAssertEqual($0 as? SASError, .finished) }
		XCTAssertEqual(mac.stage, .failed)
	}

	func testTheMacTakesOneRevealAndThePhoneOneNonce() throws {
		let keys = Keys()
		var phone = SASInitiator(
			phoneID: keys.phoneID, macID: keys.macID, phoneLink: keys.phoneLink, phoneApprove: keys.phoneApprove)
		var mac = try SASResponder(commit: phone.commit, startedAt: 0)
		let nonce = mac.nonceMessage(macLink: keys.macLink)

		var other = nonce
		other.attempt = SASAttempt.newID()
		XCTAssertThrowsError(try phone.receive(other, listedMacLink: keys.macLink)) {
			XCTAssertEqual($0 as? SASError, .attemptMismatch)
		}
		XCTAssertEqual(phone.stage, .committed, "a nonce for another attempt leaves this one alone")

		let revealed = try phone.receive(nonce, listedMacLink: keys.macLink)
		var second = nonce
		second.mac_nonce = LinkCrypto.randomBytes(SafetyNumber.nonceLength).base64EncodedString()
		XCTAssertThrowsError(try phone.receive(second, listedMacLink: keys.macLink)) {
			XCTAssertEqual($0 as? SASError, .finished)
		}

		let number = try reveal(keys, &mac, revealed)
		XCTAssertThrowsError(try reveal(keys, &mac, revealed)) { XCTAssertEqual($0 as? SASError, .finished) }
		XCTAssertEqual(mac.number(phoneLink: keys.phoneLink.x963Base64, phoneApprove: keys.phoneApprove.x963Base64, macLink: keys.macLink), number)
	}

	func testANonceNamingAnotherMacKeyThanTheListedOneFailsThePhonesAttempt() throws {
		let keys = Keys()
		var phone = SASInitiator(
			phoneID: keys.phoneID, macID: keys.macID, phoneLink: keys.phoneLink, phoneApprove: keys.phoneApprove)
		let mac = try SASResponder(commit: phone.commit, startedAt: 0)
		XCTAssertThrowsError(try phone.receive(mac.nonceMessage(macLink: keys.macLink), listedMacLink: SoftwareSigningKey().publicKey)) {
			XCTAssertEqual($0 as? SASError, .keysMismatch)
		}
		XCTAssertEqual(phone.stage, .failed)
		XCTAssertNil(phone.number)
	}

	/// The attack the commitment closes: the backend shows the Mac phone keys P' it controls and
	/// the phone a Mac key M' it controls. It must commit to P' (and its nonce) before it sees the
	/// Mac's nonce, and send the phone M' and a nonce before it sees the phone's: whatever it
	/// picks, the two numbers are independent, so it can't search for a pair that matches.
	func testABackendThatSubstitutesKeysOnBothSidesCannotLineTheNumbersUp() throws {
		let real = Keys()
		let attackerPhoneLink = SoftwareSigningKey().publicKey
		let attackerPhoneApprove = SoftwareSigningKey().publicKey
		let attackerMacLink = SoftwareSigningKey().publicKey

		// Phone ↔ backend posing as the Mac (listed to the phone with M').
		var phone = SASInitiator(
			phoneID: real.phoneID, macID: real.macID, phoneLink: real.phoneLink, phoneApprove: real.phoneApprove)
		let fakeMacSide = try SASResponder(commit: phone.commit, startedAt: 0)
		_ = try phone.receive(fakeMacSide.nonceMessage(macLink: attackerMacLink), listedMacLink: attackerMacLink)
		let phoneNumber = try XCTUnwrap(phone.number)

		// Backend posing as the phone (listed to the Mac with P', A') ↔ the Mac.
		var fakePhoneSide = SASInitiator(
			phoneID: real.phoneID, macID: real.macID, phoneLink: attackerPhoneLink, phoneApprove: attackerPhoneApprove)
		var mac = try SASResponder(commit: fakePhoneSide.commit, startedAt: 0)
		let forged = try fakePhoneSide.receive(mac.nonceMessage(macLink: real.macLink), listedMacLink: real.macLink)
		let macNumber = try mac.receive(
			forged, phoneID: real.phoneID, macID: real.macID, macLink: real.macLink, listedLink: attackerPhoneLink,
			listedApprove: attackerPhoneApprove)
		XCTAssertNotEqual(phoneNumber, macNumber)

		// Having seen the Mac's nonce, it cannot switch its reveal to other keys either.
		var late = try SASResponder(commit: fakePhoneSide.commit, startedAt: 0)
		var switched = forged
		switched.phone_link = SoftwareSigningKey().publicKey.x963Base64
		XCTAssertThrowsError(
			try late.receive(
				switched, phoneID: real.phoneID, macID: real.macID, macLink: real.macLink, listedLink: attackerPhoneLink,
				listedApprove: attackerPhoneApprove)
		) { XCTAssertEqual($0 as? SASError, .commitmentMismatch) }
	}

	// MARK: On the helper

	func testHappyPathTheCardShowsTheNumberOnlyAfterTheExchangeAndItConfirms() async throws {
		let (phone, _) = try await listedPhone()
		let before = await card(phone)
		XCTAssertTrue(before?["safety_number"] is NSNull)
		XCTAssertEqual(before?["sas_status"] as? String, "waiting")

		let number = try await phone.safetyNumber(with: account)
		let after = await card(phone)
		XCTAssertEqual(after?["safety_number"] as? String, number)
		XCTAssertEqual(after?["sas_status"] as? String, "ready")
		_ = try await account.confirmApprove(phone.deviceID, safetyNumber: number)
		XCTAssertTrue(try XCTUnwrap(helper.daemon.devices.get(phone.deviceID)).approveConfirmed)
	}

	func testAnOlderIPhoneThatNeverCommitsGetsNoNumberAndCannotBeConfirmed() async throws {
		let (phone, macID) = try await listedPhone()
		let record = try XCTUnwrap(helper.daemon.devices.get(phone.deviceID))
		let macLink = account.macLinkKey()
		let soon = await account.safetyNumberStatus(record, macLink: macLink, now: record.createdAt + 5)
		XCTAssertEqual(soon, "waiting")
		let later = await account.safetyNumberStatus(
			record, macLink: macLink, now: record.createdAt + AccountLink.sasUpdateHintAfter)
		XCTAssertEqual(later, "update_required", "the card tells the owner to update Whispera on the iPhone")

		// What an older iPhone shows: the number from the listed keys alone. Never accepted.
		let legacy = Self.legacyNumber(
			macLink: try XCTUnwrap(macLink), phoneLink: phone.linkKey.publicKey, phoneApprove: phone.approveKey.publicKey)
		await expectRefusal("peer_update_required", phone, number: legacy)
		XCTAssertNotNil(backend.device(macID))
	}

	func testARevealBeforeAnyCommitIsRefusedAndStartsNothing() async throws {
		let (phone, macID) = try await listedPhone()
		let attempt = SASInitiator(
			phoneID: phone.deviceID, macID: macID, phoneLink: phone.linkKey.publicKey,
			phoneApprove: phone.approveKey.publicKey)
		let reveal = SASReveal(
			attempt: attempt.attempt, phone_link: phone.linkKey.publicKey.x963Base64,
			phone_approve: phone.approveKey.publicKey.x963Base64,
			phone_nonce: LinkCrypto.randomBytes(SafetyNumber.nonceLength).base64EncodedString())
		try await phone.send(.sasReveal(reveal), toDevice: macID)
		try await account.processMessages()
		let stored = await account.safetyNumberAttempt(phone.deviceID)
		XCTAssertNil(stored)
		let shown = await card(phone)
		XCTAssertTrue(shown?["safety_number"] is NSNull)
		await expectRefusal("peer_update_required", phone, number: "1234 5678 9012")
		let log = try String(contentsOfFile: helper.daemon.config.paths.log, encoding: .utf8)
		XCTAssertTrue(log.contains("reveal without a commitment"))
	}

	func testARevealThatDoesNotMatchItsCommitmentFailsAndNothingCanBeConfirmed() async throws {
		let (phone, macID) = try await listedPhone()
		var attempt = try await phone.commit(toMac: macID)
		try await account.processMessages()
		let nonce = try await phone.nextNonce(attempt: attempt.attempt)
		let honest = try attempt.receive(nonce, listedMacLink: try XCTUnwrap(account.macLinkKey()))
		var reveal = honest
		reveal.phone_nonce = LinkCrypto.randomBytes(SafetyNumber.nonceLength).base64EncodedString()
		try await phone.send(.sasReveal(reveal), toDevice: macID)
		try await account.processMessages()
		let failed = await account.safetyNumberAttempt(phone.deviceID)
		XCTAssertEqual(failed?.stage, .failed)
		let failedCard = await card(phone)
		XCTAssertEqual(failedCard?["sas_status"] as? String, "failed")
		await expectRefusal("keys_changed", phone, number: try XCTUnwrap(attempt.number))

		// The honest reveal of the same attempt does not revive it.
		try await phone.send(.sasReveal(honest), toDevice: macID)
		try await account.processMessages()
		let after = await account.safetyNumberAttempt(phone.deviceID)
		XCTAssertEqual(after?.stage, .failed)
		XCTAssertNil(after?.number)
		await expectRefusal("keys_changed", phone, number: try XCTUnwrap(attempt.number))
	}

	/// H2 with the commitment: the backend lets the real phone commit, then lists the phone's id
	/// with keys it controls. The honest reveal no longer matches the listed keys and the impostor
	/// cannot open the honest commitment, so the Mac never shows a number for the new keys.
	func testKeysSubstitutedAfterTheCommitmentNeverGetANumber() async throws {
		let (phone, macID) = try await listedPhone()
		var attempt = try await phone.commit(toMac: macID)
		try await account.processMessages()
		let nonce = try await phone.nextNonce(attempt: attempt.attempt)
		let reveal = try attempt.receive(nonce, listedMacLink: try XCTUnwrap(account.macLinkKey()))

		let impostor = AccountPhone(backend: backend)
		try await impostor.register(bearer: "tok-alice", name: "Sam's iPhone")
		backend.substituteKeys(of: phone.deviceID, from: impostor.deviceID)
		_ = try await account.syncNow()

		// The honest reveal now arrives signed by keys the account no longer lists for the phone:
		// it doesn't even open. The impostor's own reveal under that commitment is refused.
		try await phone.send(.sasReveal(reveal), toDevice: macID)
		var forged = reveal
		forged.phone_link = impostor.linkKey.publicKey.x963Base64
		forged.phone_approve = impostor.approveKey.publicKey.x963Base64
		try await sendAs(phoneID: phone.deviceID, key: impostor.linkKey, .sasReveal(forged), to: macID)
		try await account.processMessages()

		let stored = await account.safetyNumberAttempt(phone.deviceID)
		XCTAssertEqual(stored?.stage, .failed)
		let shown = await card(phone)
		XCTAssertTrue(shown?["safety_number"] is NSNull)
		XCTAssertNotEqual(shown?["sas_status"] as? String, "ready")
		await expectRefusal("keys_changed", phone, number: try XCTUnwrap(attempt.number))
	}

	func testACommitmentIsUsedOnceAndAttemptsAreCapped() async throws {
		let (phone, macID) = try await listedPhone()
		let first = try await phone.commit(toMac: macID)
		try await account.processMessages()
		_ = try await phone.nextNonce(attempt: first.attempt)

		// The relay replays the same commitment: no second nonce, no fresh attempt.
		try await phone.send(.sasCommit(first.commit), toDevice: macID)
		try await account.processMessages()
		let replayed = try await phone.receive()
		XCTAssertFalse(replayed.contains { if case .sasNonce = $0 { return true } else { return false } })

		for _ in 1..<AccountLink.sasAttemptsPerHour {
			let next = try await phone.commit(toMac: macID)
			try await account.processMessages()
			_ = try await phone.nextNonce(attempt: next.attempt)
		}
		let over = try await phone.commit(toMac: macID)
		try await account.processMessages()
		let none = try await phone.receive()
		XCTAssertFalse(none.contains { if case .sasNonce = $0 { return true } else { return false } })
		let current = await account.safetyNumberAttempt(phone.deviceID)
		XCTAssertNotEqual(current?.attempt, over.attempt)
	}

	/// A backend that lists fake device ids and drops every attempt whose number doesn't suit it
	/// still gets only `sasAttemptsPerHour` guesses on this Mac, and every abandoned one leaves a
	/// warning on the cards.
	func testTheAttemptCapCountsEveryPhoneAndAbandonedAttemptsWarn() async throws {
		let (first, macID) = try await listedPhone()
		var phones = [first]
		for index in 1..<AccountLink.maxPendingAccountPhones {
			let phone = AccountPhone(backend: backend)
			try await phone.register(bearer: "tok-alice", name: "Fake \(index)")
			phones.append(phone)
		}
		_ = try await account.syncNow()
		for index in 0..<AccountLink.sasAttemptsPerHour {
			let phone = phones[index % phones.count]
			let attempt = try await phone.commit(toMac: macID)
			try await account.processMessages()
			_ = try await phone.nextNonce(attempt: attempt.attempt)
		}
		let over = try await phones[1].commit(toMac: macID)
		try await account.processMessages()
		let none = try await phones[1].receive()
		XCTAssertFalse(none.contains { if case .sasNonce = $0 { return true } else { return false } })
		let current = await account.safetyNumberAttempt(phones[1].deviceID)
		XCTAssertNotEqual(current?.attempt, over.attempt, "the cap is per Mac, not per device id")

		// Never revealed: past the timeout each open attempt is abandoned, and late reveals fail.
		let superseded = await account.unfinishedSafetyNumberAttempts().count
		XCTAssertEqual(superseded, AccountLink.sasAttemptsPerHour - phones.count, "each replaced attempt counted")
		await account.expireSafetyNumberAttempts(now: Int(Date().timeIntervalSince1970) + AccountLink.sasRevealTimeout)
		let unfinished = await account.unfinishedSafetyNumberAttempts()
		XCTAssertEqual(unfinished.count, AccountLink.sasAttemptsPerHour)
		XCTAssertEqual(unfinished.filter { $0.reason == "abandoned" }.count, phones.count)
		let gone = await account.safetyNumberAttempt(first.deviceID)
		XCTAssertNil(gone)
		let cards = await account.pendingConfirmations()
		XCTAssertEqual(cards.count, phones.count)
		XCTAssertTrue(cards.allSatisfy { $0["sas_unfinished"] as? Int == AccountLink.sasAttemptsPerHour })
	}

	func testALateRevealAfterTheTimeoutIsRefused() async throws {
		let (phone, macID) = try await listedPhone()
		var attempt = try await phone.commit(toMac: macID)
		try await account.processMessages()
		let nonce = try await phone.nextNonce(attempt: attempt.attempt)
		let reveal = try attempt.receive(nonce, listedMacLink: try XCTUnwrap(account.macLinkKey()))
		await account.expireSafetyNumberAttempts(now: Int(Date().timeIntervalSince1970) + AccountLink.sasRevealTimeout)
		try await phone.send(.sasReveal(reveal), toDevice: macID)
		try await account.processMessages()
		let card = await card(phone)
		XCTAssertTrue(card?["safety_number"] is NSNull)
		XCTAssertEqual(card?["sas_unfinished"] as? Int, 1)
		await expectRefusal("peer_update_required", phone, number: try XCTUnwrap(attempt.number))
	}

	func testOnlyAFewUnconfirmedAccountPhonesArePinnedAtOnce() async throws {
		let (first, _) = try await listedPhone()
		var extra: [AccountPhone] = []
		for index in 0..<AccountLink.maxPendingAccountPhones {
			let phone = AccountPhone(backend: backend)
			try await phone.register(bearer: "tok-alice", name: "Phone \(index)")
			extra.append(phone)
		}
		let report = try await account.syncNow()
		XCTAssertEqual(report.deferred.count, 1)
		let pending = await account.pendingConfirmations()
		XCTAssertEqual(pending.count, AccountLink.maxPendingAccountPhones)
		let waiting = try XCTUnwrap(report.deferred.first)
		XCTAssertNil(helper.daemon.devices.get(waiting))

		// Confirming one frees a slot.
		let number = try await first.safetyNumber(with: account)
		_ = try await account.confirmApprove(first.deviceID, safetyNumber: number)
		let next = try await account.syncNow()
		XCTAssertEqual(next.deferred, [])
		XCTAssertNotNil(helper.daemon.devices.get(waiting))
	}

	// MARK: Helpers

	/// Seals `message` as `phoneID` with `key`: a backend holding the substituted keys.
	private func sendAs(phoneID: String, key: SoftwareSigningKey, _ message: LinkMessage, to macID: String) async throws {
		let mac = try XCTUnwrap(backend.device(macID))
		let envelope = try SealedEnvelope.seal(
			try message.encoded(), from: phoneID, signingKey: key, to: macID,
			recipientKey: try XCTUnwrap(try mac.verifiedAgreementKey()), now: Int64(Date().timeIntervalSince1970))
		backend.inject(from: phoneID, to: macID, ciphertext: envelope.base64)
	}

	/// The pre-commitment number (`WL1-SAS`), what an older iPhone shows.
	static func legacyNumber(macLink: LinkPublicKey, phoneLink: LinkPublicKey, phoneApprove: LinkPublicKey) -> String {
		var input = Data("WL1-SAS\n".utf8)
		input.append(macLink.x963)
		input.append(phoneLink.x963)
		input.append(phoneApprove.x963)
		let digest = Array(LinkCrypto.data(hex: LinkCrypto.sha256Hex(input)) ?? Data())
		let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_000_000
		let digits = String(format: "%012llu", value)
		return [0, 4, 8].map { String(digits.dropFirst($0).prefix(4)) }.joined(separator: " ")
	}
}
