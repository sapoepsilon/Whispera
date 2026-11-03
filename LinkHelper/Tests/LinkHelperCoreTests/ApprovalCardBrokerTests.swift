import CryptoKit
import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperCore
@testable import LinkHelperXPC

/// The approval card end to end against whispera-link's fake broker (`tests/fakes/fake_broker.py`):
/// the broker opens `approvals.sock`, the card reads the request from the helper, decides, and the
/// broker verifies the Mac's signature against its own pin. Touch ID is a software key here
/// (`SoftAuthenticator`); real Touch ID cannot be pressed from a test.
///
/// Needs a whispera-link checkout: `WHISPERA_LINK_REPO`, or `../whispera-link` beside this repo.
@MainActor
final class ApprovalCardBrokerTests: XCTestCase {
	var helper: TestDaemon!
	var pins: URL!
	var macKey: P256.Signing.PrivateKey!
	var macDeviceID: String!
	var authenticator: SoftAuthenticator!
	var link: InProcessLink!
	var fakeBroker: URL!

	override func setUp() async throws {
		let env = ProcessInfo.processInfo.environment
		let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
		let wl = env["WHISPERA_LINK_REPO"].map(URL.init(fileURLWithPath:))
			?? repoRoot.deletingLastPathComponent().appendingPathComponent("whispera-link")
		fakeBroker = wl.appendingPathComponent("tests/fakes/fake_broker.py")
		guard FileManager.default.fileExists(atPath: fakeBroker.path) else {
			throw XCTSkip("no whispera-link checkout at \(wl.path) (set WHISPERA_LINK_REPO)")
		}
		helper = try TestDaemon()
		pins = helper.directory.appendingPathComponent("pins")
		try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
		macKey = P256.Signing.PrivateKey()
		macDeviceID = MacApproveKey.newDeviceID()
		try pin(macDeviceID, macKey.publicKey)
		let identity = MacApproveKey.Identity(
			deviceID: macDeviceID, keyBlob: Data(), publicKeyX963: macKey.publicKey.x963Representation, createdAt: 0)
		let enrolled = helper.daemon.enrollMacApproverJSON(MacApproveKey.enrollment(identity, name: "Test Mac"))
		XCTAssertEqual(
			(WireJSON.decodeObject(enrolled)?["mac_approver"] as? [String: Any])?["device_id"] as? String, macDeviceID)
		helper.daemon.macCard.configure(watching: { true }, launch: nil)
		authenticator = SoftAuthenticator(key: macKey)
		link = InProcessLink(daemon: helper.daemon)
	}

	override func tearDown() async throws {
		helper?.stop()
	}

	func pin(_ deviceID: String, _ key: P256.Signing.PublicKey) throws {
		try key.pemRepresentation.write(
			to: pins.appendingPathComponent(deviceID + ".pub"), atomically: true, encoding: .utf8)
	}

	// MARK: Scenarios

	func testApproveOnTheCardIsVerifiedByTheBroker() async throws {
		let broker = try startBroker(window: 30)
		let session = try await openCard(broker)
		session.approve()
		try await waitFinished(session)
		XCTAssertEqual(session.state.phase, .finished(.approved))
		XCTAssertEqual(authenticator.signCount, 1)
		let out = try await broker.result()
		XCTAssertEqual(out["decision"] as? String, "approve")
		XCTAssertEqual(out["device_id"] as? String, macDeviceID)
		XCTAssertEqual(out["outcome"] as? String, "accepted")
		XCTAssertEqual(out["verified"] as? Bool, true)
		let ack = try XCTUnwrap(out["ack"] as? [String: Any])
		XCTAssertEqual(ack["devices"] as? Int, 1, "the Mac approver counts as a device")
		XCTAssertEqual(ack["mac_card"] as? Bool, true)
	}

	func testDenyOnTheCardAfterACancelledTouchID() async throws {
		authenticator.cancelNext = true
		let broker = try startBroker(window: 30)
		let session = try await openCard(broker)
		session.approve()
		try await waitUntil { session.state.phase == .pending && session.state.notice == .authenticationCancelled }
		XCTAssertEqual(helper.daemon.approvals.pendingCount, 1, "a cancelled Touch ID sends nothing")
		session.deny()
		try await waitFinished(session)
		XCTAssertEqual(session.state.phase, .finished(.denied))
		XCTAssertEqual(authenticator.signCount, 1, "the deny is signed too")
		XCTAssertEqual(authenticator.messages.last?.prefix(9), Data("WL1-DENY\n".utf8))
		let out = try await broker.result()
		XCTAssertEqual(out["decision"] as? String, "deny")
		XCTAssertEqual(out["device_id"] as? String, macDeviceID)
		XCTAssertEqual(out["outcome"] as? String, "accepted")
		XCTAssertEqual(out["verified"] as? Bool, true, "the broker verifies the deny over WL1-DENY")
	}

	func testThePhoneAnsweringFirstClosesTheCard() async throws {
		let phone = try await helper.pairedPhone()
		try pin(phone.deviceID, try P256.Signing.PublicKey(x963Representation: phone.approveKey.publicKey.x963))
		let broker = try startBroker(window: 30)
		let session = try await openCard(broker)
		let signature = try phone.approveKey.sign(session.request.signedMessage)
		let response = try await phone.call(
			"POST", "/v1/approvals/\(session.request.requestID)/decision",
			json: ["decision": "approve", "signature": signature.base64EncodedString()])
		XCTAssertEqual(response.status, 200)
		try await waitFinished(session)
		XCTAssertEqual(session.state.phase, .finished(.approvedElsewhere(phone.deviceID)))
		XCTAssertEqual(authenticator.signCount, 0)
		let out = try await broker.result()
		XCTAssertEqual(out["device_id"] as? String, phone.deviceID)
		XCTAssertEqual(out["outcome"] as? String, "accepted")
	}

	func testTheBrokersTouchIDWinningClosesTheCard() async throws {
		let broker = try startBroker(window: 30, cancelAfter: 1.5, cancelReason: "touchid_approved")
		let session = try await openCard(broker)
		try await waitFinished(session)
		XCTAssertEqual(session.state.phase, .finished(.approvedElsewhere("touchid")))
		let out = try await broker.result()
		XCTAssertEqual(out["outcome"] as? String, "cancelled")
		XCTAssertNil(out["decision"] as? String)
	}

	func testTheCardExpiresWithTheRequest() async throws {
		let broker = try startBroker(window: 4)
		let session = try await openCard(broker)
		session.startTimer()
		try await waitFinished(session, timeout: 10)
		XCTAssertEqual(session.state.phase, .finished(.expired))
		session.approve()
		XCTAssertEqual(authenticator.signCount, 0)
		let out = try await broker.result()
		XCTAssertEqual(out["outcome"] as? String, "timeout")
		XCTAssertNil(out["decision"] as? String)
	}

	// MARK: Plumbing

	/// What the app does on `approvalsChanged`: read the request, open a card, refresh it on
	/// every later change.
	func openCard(_ broker: BrokerProcess) async throws -> ApprovalCardSession {
		let requestID = try await broker.requestID()
		let data = await link.approval(requestID)
		let view = try XCTUnwrap(data.flatMap(WireJSON.decodeObject))
		let request = try ApprovalRequest(view: view, requestID: requestID)
		XCTAssertEqual(request.caller, "fake broker test")
		XCTAssertEqual(request.host, "fakehost")
		let session = ApprovalCardSession(request: request, link: link, authenticator: authenticator)
		helper.daemon.approvals.onChange { [weak session] in
			Task { @MainActor in await session?.refresh() }
		}
		return session
	}

	func startBroker(window: Int, cancelAfter: Double? = nil, cancelReason: String? = nil) throws -> BrokerProcess {
		var arguments = [
			fakeBroker.path, "--socket", helper.daemon.config.paths.approvalsSocket, "--pem", pins.path,
			"--window", String(window), "--grace", "1",
			"--request-file", helper.directory.appendingPathComponent("request-\(UUID().uuidString)").path,
		]
		if let cancelAfter { arguments += ["--cancel-after", String(cancelAfter)] }
		if let cancelReason { arguments += ["--cancel-reason", cancelReason] }
		return try BrokerProcess(arguments: arguments)
	}

	func waitFinished(_ session: ApprovalCardSession, timeout: TimeInterval = 8) async throws {
		try await waitUntil(timeout: timeout) { session.state.isFinished }
	}

	func waitUntil(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) async throws {
		let end = Date().addingTimeInterval(timeout)
		while !condition() {
			guard Date() < end else { throw TimedOut() }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
	}
}

struct TimedOut: Error {}

/// `fake_broker.py` as a child process; its one JSON line is the broker's view of the outcome.
final class BrokerProcess: @unchecked Sendable {
	let process = Process()
	let output = Pipe()
	let requestFile: String

	init(arguments: [String]) throws {
		requestFile = arguments[arguments.firstIndex(of: "--request-file")! + 1]
		process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
		process.arguments = arguments
		process.standardOutput = output
		process.standardError = FileHandle.standardError
		try process.run()
	}

	deinit {
		if process.isRunning { process.terminate() }
	}

	func requestID(timeout: TimeInterval = 5) async throws -> String {
		let end = Date().addingTimeInterval(timeout)
		while Date() < end {
			if let id = try? String(contentsOfFile: requestFile, encoding: .utf8), id.hasPrefix("apr_") { return id }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		throw BrokerError.noRequest
	}

	func result(timeout: TimeInterval = 15) async throws -> [String: Any] {
		let end = Date().addingTimeInterval(timeout)
		while process.isRunning {
			guard Date() < end else { throw BrokerError.stillRunning }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		let data = output.fileHandleForReading.readDataToEndOfFile()
		guard let object = WireJSON.decodeObject(data) else { throw BrokerError.noOutput(String(decoding: data, as: UTF8.self)) }
		return object
	}

	enum BrokerError: Error {
		case noRequest
		case stillRunning
		case noOutput(String)
	}
}

/// The calls `HelperXPCService` forwards, without XPC.
final class InProcessLink: ApprovalHelperLink, @unchecked Sendable {
	let daemon: LinkDaemon

	init(daemon: LinkDaemon) {
		self.daemon = daemon
	}

	func approval(_ requestID: String) async -> Data? { daemon.approvalJSON(requestID) }

	func decide(_ requestID: String, decision: String, signature: String?) async -> Data? {
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async { [daemon] in
				continuation.resume(returning: daemon.decideFromMacJSON(requestID, decision: decision, signature: signature))
			}
		}
	}
}

/// Touch ID stand-in: signs with a software P-256 key, or reports a cancelled prompt.
final class SoftAuthenticator: ApprovalAuthenticator, @unchecked Sendable {
	let key: P256.Signing.PrivateKey
	private let lock = NSLock()
	private var signs = 0
	private var signed: [Data] = []
	var cancelNext = false

	init(key: P256.Signing.PrivateKey) {
		self.key = key
	}

	var signCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return signs
	}

	/// Every message signed, in order.
	var messages: [Data] {
		lock.lock()
		defer { lock.unlock() }
		return signed
	}

	func sign(_ message: Data, reason: String) async throws -> Data {
		if takeCancel() { throw ApprovalAuthenticationError.cancelled }
		countSign(message)
		return try key.signature(for: message).derRepresentation
	}

	private func takeCancel() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let cancel = cancelNext
		cancelNext = false
		return cancel
	}

	private func countSign(_ message: Data) {
		lock.lock()
		signs += 1
		signed.append(message)
		lock.unlock()
	}

	func cancel() {}
}
