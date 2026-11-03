import WhisperaLink
import XCTest

@testable import LinkHelperCore

/// Commits need no code, so they must not let a stranger burn or crowd out a pairing: a code
/// holds a few candidate commitments, and commits are rate limited per address and in total.
final class PairingCommitLimitTests: XCTestCase {
	private final class Clock: @unchecked Sendable {
		var now = 1_800_000_000
	}

	private var directory: URL!
	private var clock: Clock!
	private var pairing: PairingManager!
	private var registry: DeviceRegistry!
	private let daemonKey = SoftwareSigningKey()

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			"pair-limit-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		registry = try DeviceRegistry(
			path: directory.appendingPathComponent("devices.json").path,
			keysDir: directory.appendingPathComponent("keys").path)
		let clock = Clock()
		self.clock = clock
		pairing = PairingManager(
			devices: registry, daemonKey: daemonKey, publicURL: { "http://127.0.0.1:1" },
			clock: { clock.now })
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
	}

	private func begin() -> String {
		(pairing.begin(ttl: 300)["code"] as! String).replacingOccurrences(of: "-", with: "")
	}

	private func garbageCommit(from address: String) throws -> (Data, String) {
		let commitment = LinkCrypto.sha256Hex(LinkCrypto.randomBytes(32))
		return try pairing.handleCommit(WireJSON.encode(["v": 2, "commitment": commitment]), from: address)
	}

	private func errorCode(_ body: () throws -> Any) -> String? {
		do {
			_ = try body()
			return nil
		} catch let error as APIError {
			return error.code
		} catch {
			return "\(error)"
		}
	}

	/// Commits as `phone` from `address`; returns the pair_id and the reveal body.
	private func commit(_ phone: SoftPhone, code: String, from address: String) throws -> [String: Any] {
		let nonce = LinkCrypto.randomBytes(32)
		let commitment = phone.commitment(code: code, daemonFP: pairing.daemonFP, nonce: nonce)
		let (ack, _) = try pairing.handleCommit(
			WireJSON.encode(["v": 2, "commitment": commitment]), from: address)
		let pairID = try XCTUnwrap(WireJSON.decodeObject(ack)?["pair_id"] as? String)
		return try phone.pairingBody(code: code, daemonFP: pairing.daemonFP, pairID: pairID, nonce: nonce)
	}

	private var phone: SoftPhone { SoftPhone(baseURL: URL(string: "http://127.0.0.1:1")!) }

	func testCommitsFromOtherAddressesBeforeAndAfterDoNotBreakTheOwnersPairing() throws {
		let code = begin()
		_ = try garbageCommit(from: "192.0.2.66")
		let owner = phone
		let reveal = try commit(owner, code: code, from: "192.0.2.10")
		_ = try garbageCommit(from: "192.0.2.67")
		XCTAssertTrue(pairing.isLive)
		let (out, _) = try pairing.handlePair(WireJSON.encode(reveal), from: "192.0.2.10")
		XCTAssertNotNil(WireJSON.decodeObject(out)?["device_id"] as? String)
		XCTAssertEqual(registry.all().count, 1)
	}

	func testCommitsArePerAddressRateLimitedAndTheWindowSlides() throws {
		_ = begin()
		for _ in 0..<PairingManager.maxCommitsPerAddress { _ = try garbageCommit(from: "192.0.2.66") }
		XCTAssertEqual(errorCode { try garbageCommit(from: "192.0.2.66") }, "pair_rate_limited")
		XCTAssertTrue(pairing.isLive, "a refused commit does not burn the code")
		XCTAssertNil(errorCode { try garbageCommit(from: "192.0.2.10") }, "other addresses are unaffected")
		clock.now += PairingManager.commitWindow + 1
		XCTAssertNil(errorCode { try garbageCommit(from: "192.0.2.66") })
	}

	func testCommitFloodIsCappedGloballyAndPerCode() throws {
		_ = begin()
		for index in 0..<PairingManager.maxCandidates { _ = try garbageCommit(from: "198.51.100.\(index)") }
		XCTAssertEqual(
			errorCode { try garbageCommit(from: "198.51.100.200") }, "pair_rate_limited",
			"a code holds at most maxCandidates commitments")
		XCTAssertTrue(pairing.isLive)

		// A new code starts with no candidates, but the global window still counts.
		_ = begin()
		var accepted = PairingManager.maxCandidates
		while accepted < PairingManager.maxCommitsTotal {
			XCTAssertNil(errorCode { try garbageCommit(from: "203.0.113.\(accepted)") })
			accepted += 1
			if accepted % PairingManager.maxCandidates == 0 { _ = begin() }
		}
		XCTAssertEqual(errorCode { try garbageCommit(from: "203.0.113.250") }, "pair_rate_limited")
	}

	func testTheOwnerStillPairsAfterAFloodOnceTheWindowPasses() throws {
		let code = begin()
		for index in 0..<PairingManager.maxCommitsTotal {
			_ = errorCode { try garbageCommit(from: "198.51.100.\(index)") }
		}
		XCTAssertEqual(errorCode { try commit(phone, code: code, from: "192.0.2.10") }, "pair_rate_limited")
		XCTAssertTrue(pairing.isLive)
	}

	func testFailureLimitsAreUnchanged() throws {
		XCTAssertEqual(PairingManager.maxFails, 5)
		XCTAssertEqual(PairingManager.maxTotalFails, 20)
		_ = begin()
		let guesser = phone
		let wrong = try guesser.pairingBody(
			code: "ZZZZZZZZ", daemonFP: pairing.daemonFP, pairID: "pc_x", nonce: LinkCrypto.randomBytes(32))
		var codes: [String?] = []
		for _ in 0..<5 { codes.append(errorCode { try pairing.handlePair(WireJSON.encode(wrong), from: "192.0.2.66") }) }
		XCTAssertEqual(codes, ["pair_code_invalid", "pair_code_invalid", "pair_code_invalid", "pair_code_invalid", "pair_locked"])
		XCTAssertTrue(pairing.isLive)
		for index in 0..<15 {
			_ = errorCode { try pairing.handlePair(WireJSON.encode(wrong), from: "198.51.100.\(index)") }
		}
		XCTAssertFalse(pairing.isLive, "twenty wrong codes in total burn the code")
	}

	func testARevealThatDoesNotOpenItsCandidateStillBurns() throws {
		let code = begin()
		let owner = phone
		let reveal = try commit(owner, code: code, from: "192.0.2.10")
		let attacker = phone
		let forged = try attacker.pairingBody(
			code: code, daemonFP: pairing.daemonFP, pairID: reveal["pair_id"] as! String,
			nonce: Data(base64Encoded: reveal["nonce"] as! String)!)
		XCTAssertEqual(errorCode { try pairing.handlePair(WireJSON.encode(forged), from: "192.0.2.66") }, "pair_locked")
		XCTAssertFalse(pairing.isLive)
		XCTAssertEqual(registry.all().count, 0)
	}
}
