import Foundation

/// An approval as the Mac card shows it, read from the broker's canonical bytes (PROTOCOL §7.1),
/// never from the helper's `display` convenience copy (§5.6).
public struct ApprovalRequest: Equatable, Sendable {
	public let requestID: String
	public let op: String
	public let summary: String
	public let key: String
	public let project: String
	public let token: String
	public let host: String
	public let caller: String
	public let via: String
	public let broker: String
	public let createdAt: Int
	public let expiresAt: Int
	public let canonical: Data

	public enum ParseError: Error, Equatable {
		case notBase64
		case notJSON
		case missingField(String)
		case requestIDMismatch
		case displayMismatch(String)
	}

	static let stringFields = ["request_id", "op", "summary", "key", "project", "token", "host", "caller", "via", "broker"]
	static let displayFields = ["op", "summary", "key", "project", "token", "host", "caller", "via", "broker"]

	public init(canonicalB64: String, requestID: String) throws {
		guard let raw = Data(base64Encoded: canonicalB64) else { throw ParseError.notBase64 }
		guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
			throw ParseError.notJSON
		}
		var strings: [String: String] = [:]
		for field in Self.stringFields {
			guard let value = object[field] as? String else { throw ParseError.missingField(field) }
			strings[field] = value
		}
		guard let created = Self.int(object["created_at"]) else { throw ParseError.missingField("created_at") }
		guard let expires = Self.int(object["expires_at"]) else { throw ParseError.missingField("expires_at") }
		guard strings["request_id"] == requestID else { throw ParseError.requestIDMismatch }
		self.requestID = requestID
		op = strings["op"]!
		summary = strings["summary"]!
		key = strings["key"]!
		project = strings["project"]!
		token = strings["token"]!
		host = strings["host"]!
		caller = strings["caller"]!
		via = strings["via"]!
		broker = strings["broker"]!
		createdAt = created
		expiresAt = expires
		canonical = raw
	}

	/// From the helper's approval view: renders from `canonical_b64` and refuses a view whose
	/// `display` disagrees with it, or whose `request_id` is not the one asked for (§5.6).
	public init(view: [String: Any], requestID: String) throws {
		guard view["request_id"] as? String == requestID else { throw ParseError.requestIDMismatch }
		guard let b64 = view["canonical_b64"] as? String else { throw ParseError.missingField("canonical_b64") }
		try self.init(canonicalB64: b64, requestID: requestID)
		if let display = view["display"] as? [String: Any] {
			let parsed = [op, summary, key, project, token, host, caller, via, broker]
			for (field, value) in zip(Self.displayFields, parsed) where (display[field] as? String ?? "") != value {
				throw ParseError.displayMismatch(field)
			}
		}
	}

	private static func int(_ value: Any?) -> Int? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
		return number.intValue
	}

	/// `WL1-APPROVE\n` + the canonical bytes: what the approve key signs (§7.2).
	public var signedMessage: Data { Data("WL1-APPROVE\n".utf8) + canonical }

	/// `WL1-DENY\n` + the canonical bytes: what the approve key signs for a deny (§7.2), so only
	/// this Mac's approver can deny on its behalf (`LinkCrypto.denialMessage`).
	public var denialMessage: Data { Data("WL1-DENY\n".utf8) + canonical }

	/// What the card's key signs for `decision`.
	public func message(for decision: ApprovalCardState.Decision) -> Data {
		decision == .approve ? signedMessage : denialMessage
	}

	/// The secret the request touches: the KEY for a save, the broker's summary for a read.
	public var secret: String { op == "save" && !key.isEmpty ? key : summary }

	/// What the Touch ID sheet says (the phone's wording, §7.3).
	public var authenticationReason: String {
		broker.isEmpty ? "approve secret access" : "approve secret access on \(broker)"
	}

	/// What the Touch ID sheet says for a deny.
	public var denialReason: String {
		broker.isEmpty ? "deny secret access" : "deny secret access on \(broker)"
	}

	public func reason(for decision: ApprovalCardState.Decision) -> String {
		decision == .approve ? authenticationReason : denialReason
	}
}

/// The approval card's state machine. Pure: the session feeds it events and runs the effects it
/// returns, so every path is testable without Touch ID, XPC or a window.
public struct ApprovalCardState: Equatable, Sendable {
	/// The card refuses to sign this close to the deadline (§5.6: `now ≥ expires_at − 2`).
	public static let signMargin = 2

	public enum Decision: String, Sendable { case approve, deny }

	public enum Phase: Equatable, Sendable {
		case pending
		/// Touch ID is up for this decision: a deny is signed like an approve (§7.2).
		case authenticating(Decision)
		case submitting(Decision)
		case finished(Outcome)
	}

	public enum Outcome: Equatable, Sendable {
		/// This card approved and the broker accepted the signature.
		case approved
		/// This card denied.
		case denied
		/// The broker refused this card's approval (`bad_signature`, `unknown_device`, `expired`…);
		/// it counts as a deny (§11.2).
		case rejected(String)
		/// Another approver answered first: a phone (`dev_…`) or the broker's Touch ID (`touchid`).
		case approvedElsewhere(String?)
		case deniedElsewhere(String?)
		/// The broker withdrew the request (`broker_error`, `broker_eof`).
		case cancelled(String?)
		case expired
		/// The helper or broker could not be reached; the broker's other approvers still run.
		case failed(String)
	}

	/// Why the last tap did nothing; the card words it.
	public enum Notice: Equatable, Sendable {
		case tooLate
		case authenticationCancelled
		case noKey
		/// The system's own (localized) reason.
		case authenticationFailed(String)
	}

	public enum Event: Equatable, Sendable {
		case approveTapped
		case denyTapped
		/// The prompt for `Decision` succeeded; a late answer for a prompt the card already
		/// dismissed carries the other decision (or arrives in another phase) and is ignored.
		case authenticated(Decision, signature: String)
		case authenticationFailed(Decision, Notice)
		case answered(DecisionAnswer)
		/// The approval's status as the helper reports it now.
		case remote(status: String, decidedBy: String?, reason: String?)
		case tick
	}

	public enum Effect: Equatable, Sendable {
		case authenticate(Decision, message: Data, reason: String)
		case cancelAuthentication
		case submit(Decision, signature: String)
		case close(after: TimeInterval)
	}

	public let request: ApprovalRequest
	public private(set) var phase: Phase = .pending
	public private(set) var notice: Notice?

	public init(request: ApprovalRequest) {
		self.request = request
	}

	public var isFinished: Bool {
		if case .finished = phase { return true }
		return false
	}

	public func secondsLeft(now: Int) -> Int { max(0, request.expiresAt - now) }

	public func canApprove(now: Int) -> Bool {
		phase == .pending && now < request.expiresAt - Self.signMargin
	}

	public mutating func handle(_ event: Event, now: Int) -> [Effect] {
		switch (phase, event) {
		case (.pending, .approveTapped):
			guard canApprove(now: now) else {
				notice = .tooLate
				return []
			}
			return authenticate(.approve)

		case (.pending, .denyTapped):
			return authenticate(.deny)

		case (.authenticating(.approve), .denyTapped):
			// Dismiss the approve prompt and ask again for the deny.
			return [.cancelAuthentication] + authenticate(.deny)

		case (.authenticating(let pending), .authenticated(let decision, let signature)) where pending == decision:
			if decision == .approve {
				guard now < request.expiresAt - Self.signMargin else { return finish(.expired) }
			}
			phase = .submitting(decision)
			return [.submit(decision, signature: signature)]

		case (.authenticating(let pending), .authenticationFailed(let decision, let notice)) where pending == decision:
			phase = .pending
			self.notice = notice
			return []

		case (.submitting(let decision), .answered(let answer)):
			return finish(Self.outcome(of: answer, sent: decision))

		case (.pending, .remote(let status, let decidedBy, let reason)),
			(.authenticating, .remote(let status, let decidedBy, let reason)):
			guard let outcome = Self.remoteOutcome(status: status, decidedBy: decidedBy, reason: reason) else {
				return []
			}
			return finish(outcome)

		case (.pending, .tick), (.authenticating, .tick):
			return now >= request.expiresAt ? finish(.expired) : []

		default:
			return []
		}
	}

	private mutating func authenticate(_ decision: Decision) -> [Effect] {
		notice = nil
		phase = .authenticating(decision)
		return [.authenticate(decision, message: request.message(for: decision), reason: request.reason(for: decision))]
	}

	private mutating func finish(_ outcome: Outcome) -> [Effect] {
		let wasAuthenticating: Bool
		if case .authenticating = phase { wasAuthenticating = true } else { wasAuthenticating = false }
		phase = .finished(outcome)
		notice = nil
		let close = Effect.close(after: outcome == .approved || outcome == .denied ? 1.2 : 2.5)
		return wasAuthenticating ? [.cancelAuthentication, close] : [close]
	}

	static func outcome(of answer: DecisionAnswer, sent decision: Decision) -> Outcome {
		if let code = answer.errorCode {
			switch code {
			case "approval_not_pending":
				return remoteOutcome(status: answer.status ?? "cancelled", decidedBy: nil, reason: nil)
					?? .cancelled(nil)
			case "approval_expired": return .expired
			case "bad_signature", "no_mac_approver": return .rejected(code)
			case "broker_unavailable": return .failed("The broker went away before it answered.")
			case "broker_timeout": return .failed("The broker didn't confirm in time.")
			default: return .failed(answer.message ?? code)
			}
		}
		switch (answer.status, decision) {
		case ("approved", .approve) where answer.brokerOutcome == "accepted": return .approved
		case ("denied", .deny): return .denied
		case ("denied", .approve), ("approved", .approve): return .rejected(answer.brokerOutcome ?? "denied")
		case ("cancelled", _), ("expired", _):
			return remoteOutcome(status: answer.status ?? "", decidedBy: nil, reason: nil) ?? .cancelled(nil)
		default: return .failed(answer.message ?? "Unexpected answer from the Mac link.")
		}
	}

	static func remoteOutcome(status: String, decidedBy: String?, reason: String?) -> Outcome? {
		switch status {
		case "pending": return nil
		case "approved": return .approvedElsewhere(decidedBy)
		case "denied": return .deniedElsewhere(decidedBy)
		case "expired": return .expired
		case "cancelled":
			switch reason {
			case "touchid_approved": return .approvedElsewhere("touchid")
			case "touchid_denied": return .deniedElsewhere("touchid")
			case "timeout": return .expired
			default: return .cancelled(reason)
			}
		default: return .cancelled(reason)
		}
	}
}

/// The helper's answer to a card decision, from its JSON reply.
public struct DecisionAnswer: Equatable, Sendable {
	public var status: String?
	public var brokerOutcome: String?
	public var errorCode: String?
	public var message: String?

	public init(status: String? = nil, brokerOutcome: String? = nil, errorCode: String? = nil, message: String? = nil) {
		self.status = status
		self.brokerOutcome = brokerOutcome
		self.errorCode = errorCode
		self.message = message
	}

	public init(json: Data?) {
		guard let json, let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
			self.init(errorCode: "helper_unreachable", message: "The Mac link didn't answer.")
			return
		}
		if let error = object["error"] as? [String: Any] {
			self.init(
				status: error["status"] as? String, errorCode: error["code"] as? String ?? "error",
				message: error["message"] as? String)
		} else {
			self.init(status: object["status"] as? String, brokerOutcome: object["broker_outcome"] as? String)
		}
	}
}
