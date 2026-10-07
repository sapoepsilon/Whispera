import Foundation
import WhisperaLink
import XCTest

@testable import LinkHelperXPC

final class ApprovalCardStateTests: XCTestCase {
	static let created = 1_791_158_400

	static func canonical(
		requestID: String = "apr_aaaaaaaaaaaaaaaaaaaaaaaa", op: String = "bws", key: String = "",
		expiresIn: Int = 300, token: String? = nil, caller: String = "agent mcp", host: String = "build-box"
	) -> Data {
		let object: [String: Any] = [
			"v": 1, "request_id": requestID, "nonce": "bm9uY2Vub25jZW5vbmNlMQ", "op": op, "key": key,
			"summary": op == "save" ? "save \(key) → fake-project" : "read secret 3f1c2a9b…",
			"project": "fake-project", "token": token ?? (op == "save" ? "write" : "read"), "host": host,
			"caller": caller, "via": "ssh session to build-box", "broker": "Fake Broker",
			"created_at": created, "expires_at": created + expiresIn,
		]
		return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
	}

	static func request(
		op: String = "bws", key: String = "", expiresIn: Int = 300, token: String? = nil, caller: String = "agent mcp",
		host: String = "build-box"
	) -> ApprovalRequest {
		try! ApprovalRequest(
			canonicalB64: canonical(
				op: op, key: key, expiresIn: expiresIn, token: token, caller: caller, host: host
			).base64EncodedString(),
			requestID: "apr_aaaaaaaaaaaaaaaaaaaaaaaa")
	}

	// MARK: Parsing (§5.6: render from the canonical bytes)

	func testParsesTheCanonicalBytes() throws {
		let request = Self.request(op: "save", key: "FAKE_TEST_KEY")
		XCTAssertEqual(request.caller, "agent mcp")
		XCTAssertEqual(request.host, "build-box")
		XCTAssertEqual(request.secret, "FAKE_TEST_KEY")
		XCTAssertEqual(request.project, "fake-project")
		XCTAssertEqual(request.expiresAt - request.createdAt, 300)
		XCTAssertEqual(
			request.authenticationReason, "approve saving FAKE_TEST_KEY (write token) for agent mcp on build-box")
		XCTAssertEqual(request.signedMessage, Data("WL1-APPROVE\n".utf8) + Self.canonical(op: "save", key: "FAKE_TEST_KEY"))
		XCTAssertEqual(Self.request().secret, "read secret 3f1c2a9b…")
	}

	func testRefusesAViewForAnotherRequest() {
		let view: [String: Any] = [
			"request_id": "apr_bbbbbbbbbbbbbbbbbbbbbbbb", "canonical_b64": Self.canonical().base64EncodedString(),
		]
		XCTAssertThrowsError(try ApprovalRequest(view: view, requestID: "apr_bbbbbbbbbbbbbbbbbbbbbbbb")) {
			XCTAssertEqual($0 as? ApprovalRequest.ParseError, .requestIDMismatch)
		}
	}

	func testRefusesADisplayThatDisagreesWithTheCanonicalBytes() {
		let view: [String: Any] = [
			"request_id": "apr_aaaaaaaaaaaaaaaaaaaaaaaa", "canonical_b64": Self.canonical().base64EncodedString(),
			"display": [
				"op": "bws", "summary": "read secret 3f1c2a9b…", "key": "", "project": "fake-project",
				"token": "read", "host": "another-box", "caller": "agent mcp", "via": "ssh session to build-box",
				"broker": "Fake Broker",
			],
		]
		XCTAssertThrowsError(try ApprovalRequest(view: view, requestID: "apr_aaaaaaaaaaaaaaaaaaaaaaaa")) {
			XCTAssertEqual($0 as? ApprovalRequest.ParseError, .displayMismatch("host"))
		}
	}

	// MARK: What the owner is shown (M6, M7)

	func testTheTouchIDReasonNamesTheSecretTokenAgentAndHost() {
		XCTAssertEqual(
			Self.request(key: "GITHUB_TOKEN", caller: "deploy-bot").authenticationReason,
			"approve reading GITHUB_TOKEN (read token) for deploy-bot on build-box")
		XCTAssertEqual(
			Self.request(key: "GITHUB_TOKEN", caller: "deploy-bot").denialReason,
			"deny reading GITHUB_TOKEN (read token) for deploy-bot on build-box")
		XCTAssertEqual(
			Self.request(key: "GITHUB_TOKEN", token: "write", caller: "deploy-bot").authenticationReason,
			"approve reading GITHUB_TOKEN (write token) for deploy-bot on build-box")
		XCTAssertEqual(
			Self.request(op: "save", key: "NEW_KEY", caller: "", host: "").authenticationReason,
			"approve saving NEW_KEY (write token)")
	}

	func testTheTouchIDReasonStripsUnsafeTextAndIsBounded() {
		let request = Self.request(
			key: "GITHUB\u{202E}_TOKEN", caller: "git (pid 1)\nApproved by the owner" + String(repeating: "x", count: 80),
			host: "build\u{200B}-box\u{2066}")
		let reason = request.authenticationReason
		XCTAssertFalse(reason.unicodeScalars.contains(where: ApprovalRequest.isUnsafe), reason)
		XCTAssertTrue(reason.hasPrefix("approve reading GITHUB_TOKEN (read token) for git (pid 1)Approved by the owner"), reason)
		XCTAssertTrue(reason.hasSuffix("… on build-box"), reason)
		XCTAssertLessThan(reason.count, 64 + 40 + 40 + 60)
	}

	func testTheTokenKind() {
		XCTAssertEqual(Self.request().tokenKind, .read)
		XCTAssertEqual(Self.request(op: "save", key: "K").tokenKind, .write)
		XCTAssertEqual(Self.request(token: "READ").tokenKind, .read)
		XCTAssertEqual(Self.request(token: "admin").tokenKind, .other("admin"))
	}

	func testUnsafeScalarsAreTheSetTheParserRefuses() {
		for value in UInt32(0)...0x3000 {
			guard let scalar = Unicode.Scalar(value) else { continue }
			XCTAssertEqual(ApprovalRequest.isUnsafe(scalar), CanonicalApproval.isUnsafe(scalar), String(value, radix: 16))
		}
		for value: UInt32 in [0xFEFF, 0xFEFE, 0xFFFD, 0x1F600] {
			let scalar = Unicode.Scalar(value)!
			XCTAssertEqual(ApprovalRequest.isUnsafe(scalar), CanonicalApproval.isUnsafe(scalar), String(value, radix: 16))
		}
		XCTAssertEqual(ApprovalRequest.displayable("a\u{202E}b\u{0007}c\u{FEFF}d\nе"), "abcdе")
	}

	// MARK: State machine

	func testApproveAuthenticatesThenSubmitsTheSignature() {
		var state = ApprovalCardState(request: Self.request())
		let now = Self.created + 10
		XCTAssertEqual(
			state.handle(.approveTapped, now: now),
			[
				.authenticate(
					.approve, message: state.request.signedMessage,
					reason: "approve read secret 3f1c2a9b… (read token) for agent mcp on build-box")
			])
		XCTAssertEqual(state.phase, .authenticating(.approve))
		XCTAssertEqual(
			state.handle(.authenticated(.approve, signature: "c2ln"), now: now + 2), [.submit(.approve, signature: "c2ln")])
		XCTAssertEqual(state.phase, .submitting(.approve))
		XCTAssertEqual(
			state.handle(.answered(DecisionAnswer(status: "approved", brokerOutcome: "accepted")), now: now + 3),
			[.close(after: 1.2)])
		XCTAssertEqual(state.phase, .finished(.approved))
	}

	func testDenyIsSignedLikeAnApprove() {
		var state = ApprovalCardState(request: Self.request())
		let request = state.request
		XCTAssertEqual(request.denialMessage, Data("WL1-DENY\n".utf8) + Self.canonical())
		XCTAssertEqual(
			state.handle(.denyTapped, now: Self.created),
			[
				.authenticate(
					.deny, message: request.denialMessage,
					reason: "deny read secret 3f1c2a9b… (read token) for agent mcp on build-box")
			])
		XCTAssertEqual(state.phase, .authenticating(.deny))
		XCTAssertEqual(state.handle(.authenticated(.deny, signature: "bm8="), now: Self.created), [.submit(.deny, signature: "bm8=")])
		_ = state.handle(.answered(DecisionAnswer(status: "denied", brokerOutcome: "accepted")), now: Self.created)
		XCTAssertEqual(state.phase, .finished(.denied))
	}

	func testACancelledDenyPromptSendsNothing() {
		var state = ApprovalCardState(request: Self.request())
		_ = state.handle(.denyTapped, now: Self.created)
		XCTAssertEqual(state.handle(.authenticationFailed(.deny, .authenticationCancelled), now: Self.created), [])
		XCTAssertEqual(state.phase, .pending)
	}

	func testDenyDuringTouchIDDismissesThePromptAndAsksForTheDeny() {
		var state = ApprovalCardState(request: Self.request())
		let request = state.request
		_ = state.handle(.approveTapped, now: Self.created)
		XCTAssertEqual(
			state.handle(.denyTapped, now: Self.created),
			[.cancelAuthentication, .authenticate(.deny, message: request.denialMessage, reason: request.denialReason)])
		// The dismissed approve prompt answers late either way: neither counts.
		XCTAssertEqual(state.handle(.authenticationFailed(.approve, .authenticationCancelled), now: Self.created), [])
		XCTAssertEqual(state.handle(.authenticated(.approve, signature: "late"), now: Self.created), [])
		XCTAssertEqual(state.phase, .authenticating(.deny))
		XCTAssertEqual(state.handle(.authenticated(.deny, signature: "bm8="), now: Self.created), [.submit(.deny, signature: "bm8=")])
		XCTAssertEqual(state.phase, .submitting(.deny))
	}

	func testCancelledTouchIDSendsNothingAndReturnsToPending() {
		var state = ApprovalCardState(request: Self.request())
		_ = state.handle(.approveTapped, now: Self.created)
		XCTAssertEqual(state.handle(.authenticationFailed(.approve, .authenticationCancelled), now: Self.created), [])
		XCTAssertEqual(state.phase, .pending)
		XCTAssertEqual(state.notice, .authenticationCancelled)
	}

	func testRefusesToSignInTheLastTwoSeconds() {
		var state = ApprovalCardState(request: Self.request(expiresIn: 100))
		XCTAssertEqual(state.handle(.approveTapped, now: Self.created + 98), [])
		XCTAssertEqual(state.phase, .pending)
		XCTAssertEqual(state.notice, .tooLate)
	}

	func testATouchIDThatEndsTooLateIsNotSent() {
		var state = ApprovalCardState(request: Self.request(expiresIn: 100))
		_ = state.handle(.approveTapped, now: Self.created + 90)
		XCTAssertEqual(
			state.handle(.authenticated(.approve, signature: "c2ln"), now: Self.created + 99),
			[.cancelAuthentication, .close(after: 2.5)])
		XCTAssertEqual(state.phase, .finished(.expired))
	}

	func testTheCountdownExpiresTheCard() {
		var state = ApprovalCardState(request: Self.request(expiresIn: 300))
		XCTAssertEqual(state.secondsLeft(now: Self.created + 60), 240)
		XCTAssertEqual(state.handle(.tick, now: Self.created + 299), [])
		XCTAssertEqual(state.handle(.tick, now: Self.created + 300), [.close(after: 2.5)])
		XCTAssertEqual(state.phase, .finished(.expired))
		XCTAssertEqual(state.secondsLeft(now: Self.created + 400), 0)
	}

	func testAnAnswerElsewhereClosesTheCard() {
		let cases: [(String, String?, String?, ApprovalCardState.Outcome)] = [
			("approved", "dev_phonephonephonephonephon", nil, .approvedElsewhere("dev_phonephonephonephonephon")),
			("denied", "dev_phonephonephonephonephon", nil, .deniedElsewhere("dev_phonephonephonephonephon")),
			("cancelled", nil, "touchid_approved", .approvedElsewhere("touchid")),
			("cancelled", nil, "touchid_denied", .deniedElsewhere("touchid")),
			("cancelled", nil, "broker_eof", .cancelled("broker_eof")),
			("expired", nil, nil, .expired),
		]
		for (status, decidedBy, reason, outcome) in cases {
			var state = ApprovalCardState(request: Self.request())
			XCTAssertEqual(
				state.handle(.remote(status: status, decidedBy: decidedBy, reason: reason), now: Self.created),
				[.close(after: 2.5)], status)
			XCTAssertEqual(state.phase, .finished(outcome), status)
		}
	}

	func testAnAnswerElsewhereDuringTouchIDDismissesThePrompt() {
		var state = ApprovalCardState(request: Self.request())
		_ = state.handle(.approveTapped, now: Self.created)
		XCTAssertEqual(
			state.handle(.remote(status: "cancelled", decidedBy: nil, reason: "touchid_approved"), now: Self.created),
			[.cancelAuthentication, .close(after: 2.5)])
		XCTAssertEqual(state.handle(.authenticated(.approve, signature: "late"), now: Self.created), [])
		XCTAssertEqual(state.phase, .finished(.approvedElsewhere("touchid")))
	}

	func testPendingRefreshesAndRemoteChangesWhileSubmittingAreIgnored() {
		var state = ApprovalCardState(request: Self.request())
		XCTAssertEqual(state.handle(.remote(status: "pending", decidedBy: nil, reason: nil), now: Self.created), [])
		_ = state.handle(.denyTapped, now: Self.created)
		_ = state.handle(.authenticated(.deny, signature: "bm8="), now: Self.created)
		XCTAssertEqual(state.handle(.remote(status: "denied", decidedBy: "dev_x", reason: nil), now: Self.created), [])
		XCTAssertEqual(state.phase, .submitting(.deny))
	}

	func testBrokerAndHelperRefusalsMapToOutcomes() {
		let approve = ApprovalCardState.Decision.approve
		XCTAssertEqual(
			ApprovalCardState.outcome(of: DecisionAnswer(status: "denied", brokerOutcome: "unknown_device"), sent: approve),
			.rejected("unknown_device"))
		XCTAssertEqual(
			ApprovalCardState.outcome(of: DecisionAnswer(errorCode: "bad_signature"), sent: approve),
			.rejected("bad_signature"))
		XCTAssertEqual(
			ApprovalCardState.outcome(of: DecisionAnswer(status: "cancelled", errorCode: "approval_not_pending"), sent: approve),
			.cancelled(nil))
		XCTAssertEqual(
			ApprovalCardState.outcome(of: DecisionAnswer(errorCode: "approval_expired"), sent: approve), .expired)
		XCTAssertEqual(
			ApprovalCardState.outcome(of: DecisionAnswer(json: nil), sent: approve),
			.failed("The Mac link didn't answer."))
		XCTAssertEqual(
			ApprovalCardState.outcome(
				of: DecisionAnswer(json: Data(#"{"error":{"code":"broker_unavailable","message":"gone"}}"#.utf8)),
				sent: .deny),
			.failed("The broker went away before it answered."))
	}

	func testDeviceIDsHaveTheProtocolShape() {
		let id = MacApproveKey.newDeviceID()
		XCTAssertNotNil(id.range(of: "^dev_[a-z2-7]{24}$", options: .regularExpression), id)
		XCTAssertEqual(MacApproveKey.base32([0x66, 0x6f, 0x6f, 0x62, 0x61]), "mzxw6ytb")
	}
}
