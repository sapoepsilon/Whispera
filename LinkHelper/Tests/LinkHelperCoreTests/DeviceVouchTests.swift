import CryptoKit
import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// A device of the fake account with its own keys (any platform).
private final class ListedDevice {
	let linkKey = SoftwareSigningKey()
	let approveKey = SoftwareSigningKey()
	let agreementKey = SoftwareAgreementKey()
	var deviceID = ""

	static func register(_ backend: FakeAccountBackend, _ platform: Platform, name: String) async throws -> ListedDevice {
		let device = ListedDevice()
		let listed = try await AccountDeviceRegistration.register(
			baseURL: backend.baseURL, accountToken: "tok-alice", name: name, platform: platform,
			linkKey: device.linkKey, approveKey: platform == .ios ? device.approveKey.publicKey : nil,
			agreementKey: device.agreementKey.publicKey, transport: backend)
		device.deviceID = listed.device_id
		return device
	}
}

/// The vouch rules on their own: only a Mac the owner approved vouches, only for exactly the
/// listed keys, only until the vouch expires, and never in a chain.
final class DeviceVouchTests: XCTestCase {
	private var backend: FakeAccountBackend!
	private var me: ListedDevice!
	private var approvedMac: ListedDevice!
	private var phone: ListedDevice!
	private let now = 2_000_000

	override func setUp() async throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		me = try await ListedDevice.register(backend, .macos, name: "New Mac")
		approvedMac = try await ListedDevice.register(backend, .macos, name: "Trusted Mac")
		phone = try await ListedDevice.register(backend, .ios, name: "iPhone")
	}

	private var account: AccountDevices {
		AccountDevices(classifying: backend.devices(ofAccount: "alice"), selfID: me.deviceID)
	}

	private func listed(_ device: ListedDevice) throws -> TrustedDevice {
		try XCTUnwrap(account.peer(device.deviceID))
	}

	private func vouch(by voucher: ListedDevice, for subject: ListedDevice, at: Int? = nil, lifetime: Int = DeviceVouch.lifetime)
		throws -> DeviceVouch
	{
		try DeviceVouch.issue(
			voucherID: voucher.deviceID, key: voucher.linkKey, for: try listed(subject), evidence: .safetyNumber,
			issuedAt: at ?? now - 100, lifetime: lifetime)
	}

	private func roots(_ devices: ListedDevice...) throws -> [String: PinnedDeviceKeys] {
		var out: [String: PinnedDeviceKeys] = [:]
		for device in devices { out[device.deviceID] = PinnedDeviceKeys(try listed(device)) }
		return out
	}

	private func accepted(_ vouches: [DeviceVouch], roots: [String: PinnedDeviceKeys]? = nil) throws -> [String: DeviceVouch] {
		VouchTrust.accepted(
			roots: try roots ?? self.roots(approvedMac), account: account, vouches: vouches, selfID: me.deviceID, now: now)
	}

	func testAValidVouchFromAnApprovedMacIsAccepted() async throws {
		let vouch = try vouch(by: approvedMac, for: phone)
		XCTAssertTrue(vouch.isSigned(by: approvedMac.linkKey.publicKey))
		XCTAssertEqual(try accepted([vouch]), [phone.deviceID: vouch])
	}

	func testAnUnsignedVouchIsRejected() async throws {
		var vouch = try vouch(by: approvedMac, for: phone)
		vouch.signature = ""
		XCTAssertEqual(try accepted([vouch]), [:])
	}

	func testForgedTamperedAndMovedVouchesAreRejected() async throws {
		let forged = try DeviceVouch.issue(
			voucherID: approvedMac.deviceID, key: SoftwareSigningKey(), for: try listed(phone), evidence: .safetyNumber,
			issuedAt: now)
		var tampered = try vouch(by: approvedMac, for: phone)
		tampered.subject_link_pubkey = SoftwareSigningKey().publicKey.x963Base64
		var stretched = try vouch(by: approvedMac, for: phone)
		stretched.expires_at += 86_400
		var moved = try vouch(by: approvedMac, for: phone)
		moved.subject_id = me.deviceID
		XCTAssertEqual(try accepted([forged, tampered, stretched, moved]), [:])
	}

	func testAVouchFromAListedButUnapprovedMacIsRejected() async throws {
		// The backend lists the signer and it signs genuinely, but the owner never approved it here.
		let attacker = try await ListedDevice.register(backend, .macos, name: "Sam's MacBook Pro")
		XCTAssertEqual(try accepted([try vouch(by: attacker, for: phone)]), [:])
		XCTAssertEqual(try accepted([try vouch(by: approvedMac, for: phone)], roots: [:]), [:])
	}

	func testAPhoneNeverVouchesEvenWhenPinnedAsARoot() async throws {
		let otherPhone = try await ListedDevice.register(backend, .ios, name: "Other iPhone")
		let fromPhone = try vouch(by: phone, for: otherPhone)
		XCTAssertTrue(fromPhone.isSigned(by: phone.linkKey.publicKey))
		XCTAssertEqual(try accepted([fromPhone], roots: try roots(approvedMac, phone)), [:])
	}

	func testExpiredFutureAndOverlongVouchesAreRejected() async throws {
		let expired = try vouch(by: approvedMac, for: phone, at: now - DeviceVouch.lifetime - 1)
		XCTAssertFalse(expired.isCurrent(now: now))
		let future = try vouch(by: approvedMac, for: phone, at: now + VouchTrust.futureSkew + 1)
		let overlong = try vouch(by: approvedMac, for: phone, lifetime: DeviceVouch.maxLifetime + 1)
		XCTAssertFalse(overlong.isWellFormed)
		XCTAssertEqual(try accepted([expired, future, overlong]), [:])
		XCTAssertEqual(try accepted([try vouch(by: approvedMac, for: phone, at: now - DeviceVouch.lifetime + 60)]).count, 1)
	}

	func testNoChains() async throws {
		let middle = try await ListedDevice.register(backend, .macos, name: "Middle Mac")
		let toMiddle = try vouch(by: approvedMac, for: middle)
		let toPhone = try vouch(by: middle, for: phone)
		XCTAssertEqual(Set(try accepted([toMiddle, toPhone]).keys), [middle.deviceID], "an accepted Mac vouches for nothing")
	}

	func testRevokedVoucherOrSubjectAndARekeyedVoucherVouchForNothing() async throws {
		let vouch = try vouch(by: approvedMac, for: phone)
		let pinned = try roots(approvedMac)
		backend.revoke(phone.deviceID)
		XCTAssertEqual(try accepted([vouch], roots: pinned), [:])

		let other = try await ListedDevice.register(backend, .ios, name: "Other")
		let second = try self.vouch(by: approvedMac, for: other)
		let donor = try await ListedDevice.register(backend, .macos, name: "Reinstall")
		backend.substituteKeys(of: approvedMac.deviceID, from: donor.deviceID)
		XCTAssertEqual(try accepted([second], roots: pinned), [:], "new keys need a fresh approval")
		backend.revoke(approvedMac.deviceID)
		XCTAssertEqual(try accepted([second], roots: pinned), [:])
	}

	func testASubjectWhoseKeysChangedSinceTheVouchIsRejected() async throws {
		let vouch = try vouch(by: approvedMac, for: phone)
		let donor = try await ListedDevice.register(backend, .ios, name: "Other")
		backend.substituteKeys(of: phone.deviceID, from: donor.deviceID)
		XCTAssertEqual(try accepted([vouch]), [:])
	}

	/// The same bytes and signature the iPhone's copy (`WhisperaTests/DeviceVouchTests`) checks.
	func testWireVector() throws {
		let vouch = DeviceVouch(
			v: 2, voucher_id: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", subject_id: "dev_bbbbbbbbbbbbbbbbbbbbbbbb",
			subject_platform: "macos", subject_link_pubkey: Self.vectorLink, subject_approve_pubkey: Self.vectorApprove,
			subject_kem_pubkey: Self.vectorKEM, evidence: "owner_approval", issued_at: 1_790_000_000,
			expires_at: 1_792_592_000, signature: Self.vectorSignature)
		XCTAssertEqual(
			String(decoding: vouch.signedBytes, as: UTF8.self),
			"WL1-VOUCH\n2\ndev_aaaaaaaaaaaaaaaaaaaaaaaa\ndev_bbbbbbbbbbbbbbbbbbbbbbbb\nmacos\n\(Self.vectorLink)\n\(Self.vectorApprove)\n\(Self.vectorKEM)\nowner_approval\n1790000000\n1792592000"
		)
		XCTAssertTrue(vouch.isSigned(by: try LinkPublicKey(x963Base64: Self.vectorVoucher)))
		let signer = SoftwareSigningKey(try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)))
		XCTAssertEqual(signer.publicKey.x963Base64, Self.vectorVoucher)
	}

	static let vectorVoucher = "BG/wO5SSQc4drdQ1GeaWDgqFtBppoFwygQOqK84VlMoWPE91OlW/AdxT9sCwx+7ni0DG/30lqW4igrmJzvccFEo="
	static let vectorLink = "BFUPRxAD89+Xw99QaseX9nIfsaH7e49vg9IkSYplyI4kE2CT1wEuUJpzcVy9CwCjzA/0tcAbP/oZarH7MnA2uOY="
	static let vectorApprove = "BFkat3HrvP1tnLkJTRBlKK3Rpp1EwsH2J/CJ7Fi5xhrfn05qvw0EXAxpOjxorXyXynK+ZN70om/s0mPdmKkngPA="
	static let vectorKEM = "BHMQPsMLPM9X2q4I6TU0rvFEo1lAz2u7oSoM98vV1lpk2CyMmenTxF+SRbqbJ5gsmuqOwduUsZxEeVlCwOsiqjI="
	static let vectorSignature =
		"MEQCIGFyon5EYuBj+QTRa2O+CEGVrJNEIMyMdM/4gUv3Lix3AiBL1278VHtXiXjPQmIthxIEp9mJY0GRB3JXyrpZ5DPh1g=="
}

/// A tailnet as a test describes it: which owner Macs to probe, what `whois` says about each
/// probed `address:port`, and about an inbound caller (a bare address).
final class FakeTailnet: TailnetIdentity, @unchecked Sendable {
	private let lock = NSLock()
	private var macs: [TailnetPeer] = []
	private var nodes: [String: TailnetNode] = [:]
	private var inbound: TailnetNode?
	private var me: String?
	private(set) var whoisCalls = 0

	/// `nodes`: helper port → the node answering there (on 127.0.0.1).
	func set(nodes: [Int: TailnetNode], inbound: TailnetNode? = TailnetNode(id: "n-caller", name: "caller"), selfNode: String? = "n-self") {
		lock.withLock {
			macs = nodes.keys.sorted().map { TailnetPeer(address: "127.0.0.1", port: $0) }
			self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ("127.0.0.1:\($0.key)", $0.value) })
			self.inbound = inbound
			me = selfNode
		}
	}

	var selfNodeID: String? { lock.withLock { me } }
	func ownerMacs() async -> [TailnetPeer] { lock.withLock { macs } }
	/// Loopback stands in for the Tailscale IPs here; nothing else is dialled.
	func isProbeAddress(_ address: String) -> Bool { address == "127.0.0.1" }
	func whois(_ address: String) -> TailnetNode? {
		lock.withLock {
			whoisCalls += 1
			return address.contains(":") ? nodes[address] : inbound
		}
	}
}

/// Helpers of one owner on one tailnet (loopback stands in for the Tailscale IPs), the owner's
/// iPhone confirmed by its safety number on the trusted Mac only, and an attacker Mac on the
/// owner's tailnet (say, the account backend's own box) with a fake phone of its own.
final class AccountCircleTests: XCTestCase {
	var backend: FakeAccountBackend!
	var trusted: TestDaemon!
	var newMac: TestDaemon!
	let trustedTailnet = FakeTailnet()
	let newTailnet = FakeTailnet()

	override func setUpWithError() throws {
		backend = FakeAccountBackend()
		backend.addAccount("alice", bearer: "tok-alice")
		trusted = try TestDaemon(engine: FakeEngine(), accountTransport: backend, tailnet: trustedTailnet) { config in
			config.accountPollWait = -1
			config.macName = "Sam's MacBook Pro"
		}
		newMac = try TestDaemon(engine: FakeEngine(), accountTransport: backend, tailnet: newTailnet) { config in
			config.accountPollWait = -1
			config.macName = "MacBook Pro (5)"
		}
		// Who calls whom: the trusted Mac's callers are mac-b, the new Mac's are mac-a.
		trustedTailnet.set(nodes: [newMac.port: Self.macB], inbound: Self.macB, selfNode: Self.macA.id)
		newTailnet.set(nodes: [trusted.port: Self.macA], inbound: Self.macA, selfNode: Self.macB.id)
	}

	override func tearDown() {
		trusted.stop()
		newMac.stop()
	}

	static let macB = TailnetNode(id: "n-mac-b", name: "mac-b")
	static let macA = TailnetNode(id: "n-mac-a", name: "mac-a")

	/// The owner taps Link on `helper`'s card for `id`, with what the card shows.
	@discardableResult
	private func approve(_ helper: TestDaemon, _ id: String) async throws -> [String: Any] {
		let cards = await helper.daemon.account.pendingLinks()
		let card = try XCTUnwrap(cards.first { $0["device_id"] as? String == id })
		return try await helper.daemon.account.decideLink(
			id, approve: true, tailnetName: card["tailnet_name"] as? String ?? "",
			linkFingerprint: card["link_fingerprint"] as? String ?? "", name: card["name"] as? String ?? "",
			nodeID: card["node_id"] as? String ?? "")
	}

	private func join(_ helper: TestDaemon) async throws -> String {
		let status = try await helper.daemon.account.connect(bearer: "tok-alice", backendURL: backend.baseURL)
		return try XCTUnwrap(status["device_id"] as? String)
	}

	/// Both Macs joined and synced, the phone confirmed on the trusted one, and each Mac said
	/// hello to the other: candidates on both sides, nothing trusted yet.
	private func scene() async throws -> (AccountPhone, String, String) {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice", name: "Sam's iPhone")
		let trustedID = try await join(trusted)
		let newID = try await join(newMac)
		_ = try await trusted.daemon.account.syncNow()
		_ = try await trusted.daemon.account.confirmApprove(
			phone.deviceID, safetyNumber: try await phone.safetyNumber(with: trusted.daemon.account))
		_ = try await phone.receive()
		_ = try await newMac.daemon.account.syncNow()
		_ = try await trusted.daemon.account.syncNow()
		await newMac.daemon.circle.probeNow(force: true)
		await trusted.daemon.circle.probeNow(force: true)
		return (phone, trustedID, newID)
	}

	private func offers(_ messages: [LinkMessage]) -> [LinkOffer] {
		messages.compactMap { if case .linkOffer(let offer) = $0 { return offer } else { return nil } }
	}

	private func confirmed(_ helper: TestDaemon, _ id: String) -> Bool {
		helper.daemon.devices.get(id)?.approveConfirmed == true
	}

	func testATailnetProofAloneTrustsNothingAndOneApprovalOnTheNewMacLinksThePhone() async throws {
		let (phone, trustedID, newID) = try await scene()
		let report = try await newMac.daemon.account.syncNow()
		XCTAssertEqual(report.vouched, [], "proof alone grants nothing")
		XCTAssertFalse(confirmed(newMac, phone.deviceID))

		let cards = await newMac.daemon.account.pendingLinks()
		XCTAssertEqual(cards.map { $0["device_id"] as? String }, [trustedID])
		XCTAssertEqual(cards.first?["name"] as? String, "Sam's MacBook Pro")
		XCTAssertEqual(cards.first?["tailnet_name"] as? String, "mac-a")
		let theirCards = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(theirCards.map { $0["tailnet_name"] as? String }, ["mac-b"])

		// A stale card (another tailnet name than the one shown) is refused.
		do {
			_ = try await newMac.daemon.account.decideLink(
				trustedID, approve: true, tailnetName: "whispera-backend",
				linkFingerprint: cards.first?["link_fingerprint"] as? String ?? "")
			XCTFail("approved a card the owner did not see")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed")
		}

		do {
			_ = try await newMac.daemon.account.decideLink(
				trustedID, approve: true, tailnetName: "mac-a", linkFingerprint: SoftwareSigningKey().publicKey.displayFingerprint)
			XCTFail("approved keys the owner did not see")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed", "H2: a fingerprint mismatch is a 409")
		}
		let answer = try await approve(newMac, trustedID)
		// H-1: the vouch grants nothing by itself; it turns the card into "Allow, vouched by".
		XCTAssertEqual(answer["vouched"] as? [String], [phone.deviceID])
		XCTAssertFalse(confirmed(newMac, phone.deviceID))
		let pending = await newMac.daemon.account.pendingConfirmations()
		let card = try XCTUnwrap(pending.first)
		XCTAssertEqual(card["vouched_by"] as? String, trustedID)
		XCTAssertEqual(card["vouched_by_name"] as? String, "Sam's MacBook Pro")
		let fingerprint = try XCTUnwrap(card["link_fingerprint"] as? String)
		do {
			_ = try await newMac.daemon.account.confirmVouched(
				phone.deviceID, linkFingerprint: "0000-0000-0000-0000", vouchedBy: trustedID)
			XCTFail("confirmed keys the owner did not see")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed")
		}
		XCTAssertFalse(confirmed(newMac, phone.deviceID))

		// The owner's Touch ID on that card.
		do {
			_ = try await newMac.daemon.account.confirmVouched(phone.deviceID, linkFingerprint: fingerprint, vouchedBy: newID)
			XCTFail("allowed on a voucher the card did not name")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed", "the voucher shown is bound into the request")
		}
		let allowed = try await newMac.daemon.account.confirmVouched(
			phone.deviceID, linkFingerprint: fingerprint, vouchedBy: trustedID)
		XCTAssertEqual(allowed["notified"] as? Bool, true)
		let record = try XCTUnwrap(newMac.daemon.devices.get(phone.deviceID))
		XCTAssertTrue(record.approveConfirmed)
		XCTAssertEqual(record.confirmEvidence, "vouch", "L-1: the evidence is stored with the confirmation")
		XCTAssertEqual(record.vouchedBy, trustedID)
		let after = await newMac.daemon.account.pendingConfirmations()
		XCTAssertTrue(after.isEmpty)
		let received = try await phone.receive()
		let offer = try XCTUnwrap(offers(received).first)
		XCTAssertEqual(offer.helper_device_id, newID)
		XCTAssertTrue(offer.approve_confirmed)
		// The new Mac does not re-vouch a phone it took on a vouch.
		XCTAssertFalse(newMac.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID })
	}

	/// H-1: a phone no linked Mac vouches for can't be allowed without its number.
	func testAPhoneWithoutAVouchCannotBeAllowedWithoutItsSafetyNumber() async throws {
		let (phone, _, _) = try await scene()
		let cards = await newMac.daemon.account.pendingConfirmations()
		let card = try XCTUnwrap(cards.first)
		XCTAssertNil(card["vouched_by"] as? String)
		do {
			_ = try await newMac.daemon.account.confirmVouched(
				phone.deviceID, linkFingerprint: card["link_fingerprint"] as? String ?? "", vouchedBy: LinkCrypto.newDeviceID())
			XCTFail("allowed without a vouch")
		} catch let error as APIError {
			XCTAssertEqual(error.code, "keys_changed")
		}
		XCTAssertFalse(confirmed(newMac, phone.deviceID))
	}

	func testAnAttackerOnTheOwnersTailnetWithFakeKeysGetsNothingWithoutTheApproval() async throws {
		let attackerTailnet = FakeTailnet()
		let attacker = try TestDaemon(engine: FakeEngine(), accountTransport: backend, tailnet: attackerTailnet) { config in
			config.accountPollWait = -1
			config.macName = "Sam's MacBook Pro"
		}
		defer { attacker.stop() }
		attackerTailnet.set(nodes: [:], selfNode: "n-backend")
		// It lists a fake phone and "confirms" it on itself, so it can vouch for it.
		let fakePhone = AccountPhone(backend: backend)
		try await fakePhone.register(bearer: "tok-alice", name: "Sam's iPhone")
		let attackerID = try await join(attacker)
		_ = try await attacker.daemon.account.syncNow()
		_ = try await attacker.daemon.account.confirmApprove(
			fakePhone.deviceID, safetyNumber: try await fakePhone.safetyNumber(with: attacker.daemon.account))
		newTailnet.set(nodes: [trusted.port: Self.macA, attacker.port: TailnetNode(id: "n-backend", name: "whispera-backend")])
		let (phone, _, _) = try await scene()
		_ = try await attacker.daemon.account.syncNow()
		await newMac.daemon.circle.probeNow(force: true)
		let report = try await newMac.daemon.account.syncNow()
		XCTAssertEqual(report.vouched, [])
		XCTAssertFalse(confirmed(newMac, fakePhone.deviceID))
		XCTAssertFalse(confirmed(newMac, phone.deviceID))
		let view = try await accountView(newMac)
		XCTAssertEqual(newMac.daemon.circle.accepted(account: view), [:])
		// The owner sees the attacker as a card with its tailnet name, and can say no.
		let cards = await newMac.daemon.account.pendingLinks()
		XCTAssertTrue(cards.contains { $0["device_id"] as? String == attackerID && $0["tailnet_name"] as? String == "whispera-backend" })
		_ = try await newMac.daemon.account.decideLink(attackerID, approve: false, tailnetName: "")
		let after = await newMac.daemon.account.pendingLinks()
		XCTAssertFalse(after.contains { $0["device_id"] as? String == attackerID }, "declined stays declined")
	}

	private func accountView(_ helper: TestDaemon) async throws -> AccountDevices {
		let id = await helper.daemon.account.deviceID
		return AccountDevices(classifying: backend.devices(ofAccount: "alice"), selfID: id)
	}

	func testApprovingTheNewMacOnTheTrustedMacGivesThePhoneASignedVouchAndCandidate() async throws {
		let (phone, trustedID, newID) = try await scene()
		_ = try await approve(trusted, newID)
		let served = trusted.daemon.circle.publishedVouches()
		let toNew = try XCTUnwrap(served.first { $0.subject_id == newID })
		XCTAssertEqual(toNew.evidence, "owner_approval")
		XCTAssertEqual(toNew.expires_at - toNew.issued_at, DeviceVouch.lifetime)

		let soft = SoftPhone(baseURL: trusted.baseURL, linkKey: phone.linkKey, approveKey: phone.approveKey)
		soft.deviceID = phone.deviceID
		let answer = try await soft.call("GET", "/v1/account/vouches")
		XCTAssertEqual(answer.status, 200)
		let raw = try JSONSerialization.data(withJSONObject: answer.json["vouches"] ?? [])
		let vouches = try JSONDecoder().decode([DeviceVouch].self, from: raw)
		let phoneView = AccountDevices(classifying: backend.devices(ofAccount: "alice"), selfID: phone.deviceID)
		let linked = VouchTrust.accepted(
			roots: [trustedID: PinnedDeviceKeys(try XCTUnwrap(phoneView.peer(trustedID)))], account: phoneView,
			vouches: vouches, selfID: phone.deviceID, now: Int(Date().timeIntervalSince1970))
		XCTAssertEqual(Array(linked.keys), [newID])
		XCTAssertNil(answer.json["links"], "M-1: no unsigned approved flags")
	}

	/// A withdrawn vouch (the trusted Mac unlinked the new one, or was revoked, or re-keyed) takes
	/// the hint away; what the owner already allowed with a tap stays.
	func testWithdrawalTakesTheHintAwayAndATapStays() async throws {
		let (phone, trustedID, newID) = try await scene()
		try await approve(newMac, trustedID)
		try await approve(trusted, newID)
		XCTAssertTrue(trusted.daemon.circle.publishedVouches().contains { $0.subject_id == newID })
		_ = try await trusted.daemon.account.decideLink(newID, approve: false, tailnetName: "")
		XCTAssertFalse(trusted.daemon.circle.publishedVouches().contains { $0.subject_id == newID })
		await newMac.daemon.circle.probeNow(force: true)
		let report = try await newMac.daemon.account.syncNow()
		XCTAssertEqual(report.vouched, [], "the trusted Mac now answers the new one with no vouches")
		let cards = await newMac.daemon.account.pendingConfirmations()
		let card = try XCTUnwrap(cards.first)
		XCTAssertNil(card["vouched_by"] as? String, "back to the safety number")
		_ = phone
	}

	func testARevokedOrRekeyedVoucherIsNoHintButAnAllowedPhoneStays() async throws {
		let (phone, trustedID, _) = try await scene()
		try await approve(newMac, trustedID)
		let cards = await newMac.daemon.account.pendingConfirmations()
		let card = try XCTUnwrap(cards.first)
		_ = try await newMac.daemon.account.confirmVouched(
			phone.deviceID, linkFingerprint: card["link_fingerprint"] as? String ?? "", vouchedBy: trustedID)
		let donor = try await ListedDevice.register(backend, .macos, name: "Reinstall")
		backend.substituteKeys(of: trustedID, from: donor.deviceID)
		_ = try await newMac.daemon.account.syncNow()
		let view = try await accountView(newMac)
		XCTAssertEqual(newMac.daemon.circle.accepted(account: view), [:], "new keys need a fresh approval")
		XCTAssertTrue(confirmed(newMac, phone.deviceID), "the owner's tap is not undone")
	}

	/// H-2: a missed listing forgets neither the link nor the node binding.
	func testLinksAndNodeBindingsSurviveAMissedListing() async throws {
		let (_, trustedID, _) = try await scene()
		try await approve(newMac, trustedID)
		let full = try await accountView(newMac)
		let myID = await newMac.daemon.account.deviceID
		let without = AccountDevices(
			classifying: backend.devices(ofAccount: "alice").filter { $0.device_id != trustedID }, selfID: myID)
		newMac.daemon.circle.update(account: without, needsTrust: false)
		XCTAssertEqual(newMac.daemon.circle.linkedMacs().count, 0, "not listed: counts for nothing")
		newMac.daemon.circle.update(account: full, needsTrust: false)
		XCTAssertEqual(newMac.daemon.circle.linkedMacs().map { $0["device_id"] as? String }, [trustedID])
		// The card for an unlinked Mac shows when its node was first seen.
		let theirs = await trusted.daemon.account.pendingLinks()
		XCTAssertNotNil(theirs.first?["first_seen"] as? Int)
	}

	/// M-3: a voucher's set counts only while fresh.
	func testAStaleVoucherSetIsIgnored() async throws {
		let (phone, trustedID, _) = try await scene()
		try await approve(newMac, trustedID)
		let vouches = trusted.daemon.circle.publishedVouches()
		XCTAssertTrue(vouches.contains { $0.subject_id == phone.deviceID })
		let now = Int(Date().timeIntervalSince1970)
		newMac.daemon.circle.setReceived(vouches, from: trustedID, at: now - AccountCircle.receivedFreshness - 1)
		let view = try await accountView(newMac)
		XCTAssertEqual(newMac.daemon.circle.accepted(account: view), [:])
		newMac.daemon.circle.setReceived(vouches, from: trustedID, at: now)
		XCTAssertEqual(Array(newMac.daemon.circle.accepted(account: view).keys), [phone.deviceID])
	}

	func testAPhoneConfirmedByItsSafetyNumberIsVouchedOnwardOneAllowedOnAVouchIsNot() async throws {
		let (phone, _, newID) = try await scene()
		_ = try await newMac.daemon.account.confirmApprove(phone.deviceID, safetyNumber: try await phone.safetyNumber(with: newMac.daemon.account))
		XCTAssertEqual(newMac.daemon.devices.get(phone.deviceID)?.confirmEvidence, "safety_number")
		XCTAssertTrue(newMac.daemon.circle.publishedVouches().contains { $0.subject_id == phone.deviceID })
	}

	func testTheHelloIsHiddenFromUnauthenticatedAndNonOwnerCallers() async throws {
		_ = try await scene()
		let nonce = LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		let ts = Int(Date().timeIntervalSince1970)
		let stranger = LinkCrypto.newDeviceID()
		let sig = LinkCrypto.base64URLNoPad(
			try SoftwareSigningKey().sign(AccountCircle.helloBytes(nonce: nonce, ts: ts, from: stranger)))
		let url = URL(string: "\(trusted.baseURL)/v1/link/peer?from=\(stranger)&nonce=\(nonce)&ts=\(ts)&sig=\(sig)")!
		let unknown = try await SoftPhone.send(URLRequest(url: url))
		XCTAssertEqual(unknown.status, 404, "a device the account does not list as a Mac")
		let whoisBefore = trustedTailnet.whoisCalls
		let unsigned = URL(string: "\(trusted.baseURL)/v1/link/peer?nonce=\(nonce)&ts=\(ts)")!
		let bare = try await SoftPhone.send(URLRequest(url: unsigned))
		XCTAssertEqual(bare.status, 404)
		XCTAssertEqual(trustedTailnet.whoisCalls, whoisBefore, "no whois for an unauthenticated hello")

		// A listed Mac's genuine hello from a node that is not the owner's.
		trustedTailnet.set(nodes: [:], inbound: nil, selfNode: Self.macA.id)
		await newMac.daemon.circle.probeNow(force: true)
		XCTAssertGreaterThan(trustedTailnet.whoisCalls, whoisBefore, "whois runs per hello")
		let after = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(after.count, 1, "nothing new learned from a non-owner node")
		_ = whoisBefore
	}

	/// H1: a hello (inbound) never makes a card; only this helper's own probe out to the node's
	/// helper port does.
	func testAnInboundHelloNeverCreatesACandidate() async throws {
		let phone = AccountPhone(backend: backend)
		try await phone.register(bearer: "tok-alice")
		_ = try await join(trusted)
		let newID = try await join(newMac)
		_ = try await trusted.daemon.account.syncNow()
		_ = try await newMac.daemon.account.syncNow()
		await newMac.daemon.circle.probeNow(force: true)
		let onNew = await newMac.daemon.account.pendingLinks()
		XCTAssertEqual(onNew.count, 1, "the new Mac probed out and saw the trusted one")
		let onTrusted = await trusted.daemon.account.pendingLinks()
		XCTAssertTrue(onTrusted.isEmpty, "the trusted Mac only got a hello")
		await trusted.daemon.circle.probeNow(force: true)
		let probedBack = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(probedBack.map { $0["device_id"] as? String }, [newID])
		XCTAssertEqual(probedBack.first?["tailnet_name"] as? String, "mac-b")
	}

	/// H1: a planted Mac answering from a node already bound to another listed Mac, or from this
	/// Mac's own node, gets no card.
	func testANodeAlreadyBoundToAnotherMacOrToThisMacIsRefused() async throws {
		let plantedTailnet = FakeTailnet()
		let planted = try TestDaemon(engine: FakeEngine(), accountTransport: backend, tailnet: plantedTailnet) { config in
			config.accountPollWait = -1
			config.macName = "MacBook Pro (5)"
		}
		defer { planted.stop() }
		// It claims mac-b's node as its own: a local process there relaying for it.
		plantedTailnet.set(nodes: [:], selfNode: Self.macB.id)
		_ = try await join(trusted)
		let newID = try await join(newMac)
		let plantedID = try await join(planted)
		_ = try await newMac.daemon.account.syncNow()
		_ = try await planted.daemon.account.syncNow()
		_ = try await trusted.daemon.account.syncNow()
		await trusted.daemon.circle.probeNow(force: true)

		// The planted helper now answers on the same node (a local process on mac-b).
		trustedTailnet.set(nodes: [newMac.port: Self.macB, planted.port: Self.macB], inbound: Self.macB, selfNode: Self.macA.id)
		await trusted.daemon.circle.probeNow(force: true)
		var cards = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(cards.map { $0["device_id"] as? String }, [newID])
		XCTAssertEqual(trusted.daemon.circle.receivedCount(plantedID), 0, "M-3: a refused node's vouches are dropped")

		// Or on this Mac's own node.
		plantedTailnet.set(nodes: [:], selfNode: Self.macA.id)
		trustedTailnet.set(nodes: [planted.port: Self.macA], selfNode: Self.macA.id)
		await trusted.daemon.circle.probeNow(force: true)
		cards = await trusted.daemon.account.pendingLinks()
		XCTAssertFalse(cards.contains { $0["device_id"] as? String == plantedID })
	}

	/// L1: a hello replayed inside the window is refused.
	func testAReplayedHelloIsRefused() async throws {
		_ = try await join(trusted)
		let newID = try await join(newMac)
		_ = try await trusted.daemon.account.syncNow()
		let pem = try String(contentsOfFile: newMac.daemon.config.paths.relayKey, encoding: .utf8)
		let key = try SoftwareSigningKey(pkcs8PEM: pem)
		let nonce = LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		let ts = Int(Date().timeIntervalSince1970)
		let sig = LinkCrypto.base64URLNoPad(try key.sign(AccountCircle.helloBytes(nonce: nonce, ts: ts, from: newID)))
		let url = URL(string: "\(trusted.baseURL)/v1/link/peer?from=\(newID)&nonce=\(nonce)&ts=\(ts)&sig=\(sig)")!
		let first = try await SoftPhone.send(URLRequest(url: url))
		XCTAssertEqual(first.status, 200)
		let replay = try await SoftPhone.send(URLRequest(url: url))
		XCTAssertEqual(replay.status, 404)
	}

	/// M3: a confirmation taken back closes what the phone has open.
	func testAKeyChangeRunsTheTrustLostHooks() async throws {
		let (phone, _, newID) = try await scene()
		_ = try await newMac.daemon.account.confirmApprove(phone.deviceID, safetyNumber: try await phone.safetyNumber(with: newMac.daemon.account))
		let lost = LockedBox<[String]>([])
		newMac.daemon.devices.onTrustLost { id in lost.mutate { $0.append(id) } }
		let reinstall = AccountPhone(backend: backend)
		try await reinstall.register(bearer: "tok-alice", name: "Reinstall")
		backend.substituteKeys(of: phone.deviceID, from: reinstall.deviceID)
		_ = try await newMac.daemon.account.syncNow()
		let deadline = Date().addingTimeInterval(2)
		while lost.value.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
		XCTAssertEqual(lost.value, [phone.deviceID])
	}

	/// M-B: a node relaying another Mac's helper answers for a node it is not: refused, and it
	/// takes no binding.
	func testAProofForAnotherNodeIsRefusedAndTakesNoBinding() async throws {
		_ = try await join(trusted)
		let newID = try await join(newMac)
		_ = try await trusted.daemon.account.syncNow()
		_ = try await newMac.daemon.account.syncNow()
		trustedTailnet.set(nodes: [newMac.port: TailnetNode(id: "n-relay", name: "relay-box")], inbound: Self.macB, selfNode: Self.macA.id)
		await trusted.daemon.circle.probeNow(force: true)
		var cards = await trusted.daemon.account.pendingLinks()
		XCTAssertTrue(cards.isEmpty, "the answer names mac-b's node, the connection went to relay-box")
		trustedTailnet.set(nodes: [newMac.port: Self.macB], inbound: Self.macB, selfNode: Self.macA.id)
		await trusted.daemon.circle.probeNow(force: true)
		cards = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(cards.map { $0["device_id"] as? String }, [newID], "the real node still binds")
		XCTAssertEqual(cards.first?["node_id"] as? String, Self.macB.id)
	}

	/// M-B: a bound Mac's hello from another node gets nothing.
	func testAHelloFromAnotherNodeThanTheBindingIsRefused() async throws {
		_ = try await scene()
		trustedTailnet.set(nodes: [newMac.port: Self.macB], inbound: TailnetNode(id: "n-elsewhere", name: "elsewhere"), selfNode: Self.macA.id)
		let pem = try String(contentsOfFile: newMac.daemon.config.paths.relayKey, encoding: .utf8)
		let key = try SoftwareSigningKey(pkcs8PEM: pem)
		let maybeID = await newMac.daemon.account.deviceID
		let newID = try XCTUnwrap(maybeID)
		let nonce = LinkCrypto.base64URLNoPad(LinkCrypto.randomBytes(32))
		let ts = Int(Date().timeIntervalSince1970)
		let sig = LinkCrypto.base64URLNoPad(try key.sign(AccountCircle.helloBytes(nonce: nonce, ts: ts, from: newID)))
		let url = URL(string: "\(trusted.baseURL)/v1/link/peer?from=\(newID)&nonce=\(nonce)&ts=\(ts)&sig=\(sig)")!
		let answer = try await SoftPhone.send(URLRequest(url: url))
		XCTAssertEqual(answer.status, 404)
	}

	/// M-B: Tailscale gave the Mac a new node. Its answers are refused (it shows as moved) until
	/// the owner taps Relink, which clears the binding without declining its keys.
	func testRelinkRecoversANodeChange() async throws {
		let (_, trustedID, newID) = try await scene()
		try await approve(trusted, newID)
		_ = trustedID
		let moved = TailnetNode(id: "n-mac-b-new", name: "mac-b")
		newTailnet.set(nodes: [trusted.port: Self.macA], inbound: Self.macA, selfNode: moved.id)
		trustedTailnet.set(nodes: [newMac.port: moved], inbound: moved, selfNode: Self.macA.id)
		await trusted.daemon.circle.probeNow(force: true)
		let movedRows = await trusted.daemon.account.movedMacs()
		XCTAssertEqual(movedRows.map { $0["device_id"] as? String }, [newID])
		XCTAssertEqual(trusted.daemon.circle.linkedMacs().count, 1, "still linked to the old binding until the owner says so")

		_ = try await trusted.daemon.account.decideLink(newID, approve: false, tailnetName: "", relink: true)
		XCTAssertTrue(trusted.daemon.circle.linkedMacs().isEmpty, "a relinked Mac needs Link again")
		XCTAssertTrue(trusted.daemon.circle.movedMacs().isEmpty, "Relink clears the moved row")
		let cards = await trusted.daemon.account.pendingLinks()
		XCTAssertEqual(cards.first?["node_id"] as? String, moved.id, "bound afresh to the new node, not declined")
		try await approve(trusted, newID)
		XCTAssertEqual(trusted.daemon.circle.linkedMacs().count, 1)
	}

	/// Lows: the card's account name and node are bound into the approval.
	func testAnApprovalForAnotherNameOrNodeIsRefused() async throws {
		let (_, trustedID, _) = try await scene()
		let cards = await newMac.daemon.account.pendingLinks()
		let card = try XCTUnwrap(cards.first)
		for (name, node) in [("Someone Else", card["node_id"] as? String ?? ""), (card["name"] as? String ?? "", "n-other")] {
			do {
				_ = try await newMac.daemon.account.decideLink(
					trustedID, approve: true, tailnetName: card["tailnet_name"] as? String ?? "",
					linkFingerprint: card["link_fingerprint"] as? String ?? "", name: name, nodeID: node)
				XCTFail("approved a card the owner did not see")
			} catch let error as APIError {
				XCTAssertEqual(error.code, "keys_changed")
			}
		}
	}

	func testTheProofSignsTheFullKeySetAndTheNode() {
		let proof = AccountCircle.PeerProof(
			v: 3, device_id: "dev_aaaaaaaaaaaaaaaaaaaaaaaa", link_pubkey: "L", approve_pubkey: nil, kem_pubkey: "K",
			node_id: "n-1", signature: "", vouches: [])
		XCTAssertEqual(
			String(decoding: proof.signedBytes(nonce: "N", verifier: "dev_bbbbbbbbbbbbbbbbbbbbbbbb"), as: UTF8.self),
			"WL1-PEER-PROOF\nN\ndev_bbbbbbbbbbbbbbbbbbbbbbbb\ndev_aaaaaaaaaaaaaaaaaaaaaaaa\nL\n-\nK\nn-1")
	}

	func testHellosHaveTheirOwnRateLimit() async throws {
		_ = try await join(trusted)
		var statuses: [Int] = []
		for _ in 0..<14 {
			let url = URL(string: "\(trusted.baseURL)/v1/link/peer?nonce=x")!
			statuses.append(try await SoftPhone.send(URLRequest(url: url)).status)
		}
		XCTAssertEqual(statuses.last, 429)
		let health = try await SoftPhone.send(URLRequest(url: trusted.baseURL.appendingPathComponent("v1/health")))
		XCTAssertEqual(health.status, 200)
	}
}

final class LockedBox<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: T
	init(_ value: T) { stored = value }
	var value: T { lock.withLock { stored } }
	func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

/// Which nodes `tailscale status --json` and `whois --json` count as the owner's.
final class TailscaleStatusTests: XCTestCase {
	func testOnlyOnlineUntaggedMacsOfTheSameUserAreProbed() throws {
		let status: [String: Any] = [
			"Self": ["UserID": 7, "TailscaleIPs": ["100.64.0.1"], "OS": "macOS"],
			"Peer": [
				"a": ["UserID": 7, "Online": true, "OS": "macOS", "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"]],
				"b": ["UserID": 7, "Online": true, "OS": "iOS", "TailscaleIPs": ["100.64.0.3"]],
				"c": ["UserID": 7, "Online": false, "OS": "macOS", "TailscaleIPs": ["100.64.0.4"]],
				"d": ["UserID": 9, "Online": true, "OS": "macOS", "TailscaleIPs": ["100.64.0.5"]],
				"e": ["UserID": 7, "Online": true, "OS": "macOS", "Tags": ["tag:server"], "TailscaleIPs": ["100.64.0.6"]],
				"f": ["UserID": 7, "Online": true, "OS": "macOS", "ShareeNode": true, "TailscaleIPs": ["100.64.0.7"]],
			],
		]
		let parsed = try XCTUnwrap(TailscaleCLIIdentity.parseStatus(try JSONSerialization.data(withJSONObject: status)))
		XCTAssertEqual(parsed.macs, [TailnetPeer(address: "100.64.0.2")])
		XCTAssertEqual(parsed.selfUser, "7")
	}

	func testWhoisNamesOnlyTheOwnersNodes() throws {
		func node(_ fields: [String: Any]) throws -> Data {
			var base: [String: Any] = [
				"Name": "mac-b.example.ts.net.", "User": 7, "Online": true, "Hostinfo": ["OS": "macOS"],
				"StableID": "n-mac-b",
			]
			base.merge(fields) { _, new in new }
			return try JSONSerialization.data(withJSONObject: ["Node": base, "UserProfile": ["ID": 7]])
		}
		XCTAssertEqual(
			TailscaleCLIIdentity.parseWhois(try node([:]), selfUser: "7"), TailnetNode(id: "n-mac-b", name: "mac-b", os: "macOS"))
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["Hostinfo": ["OS": "linux"]]), selfUser: "7"), "a Linux box is no Mac")
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["StableID": ""]), selfUser: "7"))
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["User": 9]), selfUser: "7"))
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["Tags": ["tag:ci"]]), selfUser: "7"))
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["Sharer": 9]), selfUser: "7"))
		XCTAssertNil(TailscaleCLIIdentity.parseWhois(try node(["Online": false]), selfUser: "7"))
	}
}

/// L-2 and L-1 and M-2 and L-3 on their own.
final class CircleHardeningTests: XCTestCase {
	func testProbesOfMacsNeverLinkedBackOff() {
		var schedule = ProbeSchedule()
		XCTAssertTrue(schedule.isDue("a", now: 0))
		schedule.record("a", .unlinked, now: 0)
		XCTAssertFalse(schedule.isDue("a", now: 19))
		XCTAssertTrue(schedule.isDue("a", now: 20))
		schedule.record("a", .unlinked, now: 20)
		XCTAssertFalse(schedule.isDue("a", now: 59))
		for _ in 0..<20 { schedule.record("a", .nothing, now: 100) }
		XCTAssertTrue(schedule.isDue("a", now: 100 + ProbeSchedule.ceiling))
		schedule.record("a", .linked, now: 100)
		XCTAssertTrue(schedule.isDue("a", now: 100))
	}

	func testAnUnreadableStateFileIsKeptAsideNotSilentlyReset() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circle-\(UUID().uuidString.prefix(8))")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let path = dir.appendingPathComponent("circle.json").path
		try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
		let circle = AccountCircle(path: path, tailnet: nil, defaultPort: 7787)
		XCTAssertNotNil(circle.loadError)
		let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("circle.json.unreadable-") }
		XCTAssertEqual(kept.count, 1)
		// An older file with fewer fields still loads.
		try Data(#"{"approved":{},"declined":["x"]}"#.utf8).write(to: URL(fileURLWithPath: path))
		XCTAssertNil(AccountCircle(path: path, tailnet: nil, defaultPort: 7787).loadError)
	}

	func testADeviceRecordKeepsItsEvidenceAndOldRecordsDecode() throws {
		let old = DeviceRecord(json: [
			"device_id": "dev_aaaaaaaaaaaaaaaaaaaaaaaa", "link_pubkey": "x", "approve_pubkey": "y", "origin": "account",
			"approve_confirmed": true,
		])
		XCTAssertEqual(old?.confirmEvidence, "safety_number")
		let vouched = DeviceRecord(json: [
			"device_id": "dev_aaaaaaaaaaaaaaaaaaaaaaaa", "link_pubkey": "x", "approve_pubkey": "y", "origin": "account",
			"approve_confirmed": true, "confirm_evidence": "vouch", "vouched_by": "dev_bbbbbbbbbbbbbbbbbbbbbbbb",
		])
		XCTAssertEqual(vouched?.confirmEvidence, "vouch")
		XCTAssertEqual(vouched?.publicJSON["vouched_by"] as? String, "dev_bbbbbbbbbbbbbbbbbbbbbbbb")
	}

	func testOnlyTheSignedTailscaleAppCounts() {
		XCTAssertFalse(TailscaleCLIIdentity.isSignedByTailscale("/bin/ls"))
		XCTAssertFalse(TailscaleCLIIdentity.isSignedByTailscale("/System/Applications/Calculator.app/Contents/MacOS/Calculator"))
		if FileManager.default.fileExists(atPath: TailscaleCLIIdentity.appCLI) {
			XCTAssertTrue(TailscaleCLIIdentity.isSignedByTailscale(TailscaleCLIIdentity.appCLI))
		}
	}

	/// M-2: a probe answer over the cap, a redirect, or one past the deadline is nothing.
	func testThePeerClientCapsFollowsNoRedirectsAndHasADeadline() async throws {
		let server = try PyServer()
		defer { server.stop() }
		let http = PeerHTTP(allowsHost: { $0 == "127.0.0.1" })
		let ok = await http.get(server.url("/ok"))
		XCTAssertEqual(ok.map { String(decoding: $0, as: UTF8.self) }, "hello")
		let big = await http.get(server.url("/big"), maxBytes: 1024)
		XCTAssertNil(big)
		let redirect = await http.get(server.url("/redirect"))
		XCTAssertNil(redirect)
		let started = Date()
		let slow = await http.get(server.url("/slow"), deadline: 1)
		XCTAssertNil(slow)
		XCTAssertLessThan(Date().timeIntervalSince(started), 3)
	}
}

/// A throwaway HTTP server on loopback for the peer client tests.
final class PyServer {
	let port: Int
	private let process = Process()

	init() throws {
		let script = """
			import http.server, socketserver, sys, time
			class H(http.server.BaseHTTPRequestHandler):
			    def log_message(self, *a): pass
			    def do_GET(self):
			        if self.path == "/ok":
			            self.send_response(200); self.send_header("Content-Length", "5"); self.end_headers(); self.wfile.write(b"hello")
			        elif self.path == "/big":
			            self.send_response(200); self.end_headers(); self.wfile.write(b"x" * 100000)
			        elif self.path == "/redirect":
			            self.send_response(302); self.send_header("Location", "/ok"); self.send_header("Content-Length", "0"); self.end_headers()
			        else:
			            self.send_response(200); self.send_header("Content-Length", "5"); self.end_headers(); time.sleep(10); self.wfile.write(b"late!")
			s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
			print(s.server_address[1], flush=True)
			s.serve_forever()
			"""
		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = ["-c", script]
		let out = Pipe()
		process.standardOutput = out
		try process.run()
		var line = Data()
		while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
			line.append(byte)
		}
		port = Int(String(decoding: line, as: UTF8.self)) ?? 0
	}

	func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
	func stop() { process.terminate() }
}

/// A request that reaches the API after its daemon went away is dropped, not a crash.
final class LinkAPILifetimeTests: XCTestCase {
	final class Exchange: LinkExchange, @unchecked Sendable {
		let method = "GET"
		let target = "/v1/health"
		let path = "/v1/health"
		let query = ""
		let remoteHost = "127.0.0.1"
		let headerDictionary: [String: String] = [:]
		private(set) var status = 0
		let relaySender: String? = nil
		private(set) var closed = false
		var isAlive: Bool { !closed }
		let cancelToken = CancelToken()
		func watchForDisconnect() {}
		func header(_ name: String) -> String? { nil }
		func readBody(_ count: Int, timeout: TimeInterval) throws -> Data { Data() }
		func sendContinueIfExpected() {}
		func respond(_ status: Int, contentType: String, headers: [(String, String)], body: Data) { self.status = status }
		func beginStream(_ status: Int, headers: [(String, String)]) throws { self.status = status }
		func write(_ data: Data, timeout: TimeInterval) throws {}
		func close() { closed = true }
	}

	func testARequestAfterTheDaemonIsGoneIsDropped() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wlh-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: directory) }
		var config = HelperConfig(
			paths: .init(
				config: directory.appendingPathComponent("config.json").path,
				stateDir: directory.appendingPathComponent("state").path,
				log: directory.appendingPathComponent("helper.log").path))
		config.herdrCLI = ""
		config.tmuxCLI = ""
		config.tailscaleCLI = ""
		config.herdrSocket = directory.appendingPathComponent("none.sock").path
		var daemon: LinkDaemon? = try LinkDaemon(config: config, engine: nil)
		weak var gone = daemon
		let api = LinkAPI(daemon: try XCTUnwrap(daemon))
		let alive = Exchange()
		api.handle(alive)
		XCTAssertEqual(alive.status, 200)
		daemon = nil
		guard gone == nil else { throw XCTSkip("the daemon is still referenced elsewhere; nothing to check") }
		let late = Exchange()
		api.handle(late)
		XCTAssertTrue(late.closed)
		XCTAssertEqual(late.status, 0)
	}
}
