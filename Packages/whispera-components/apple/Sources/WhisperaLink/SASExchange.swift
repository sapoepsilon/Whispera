import Foundation

/// The three relay messages that fix a `SafetyNumber` (see there for why the commitment).
///
/// ```
/// {"type":"sas_commit","v":1,"attempt":"sas_…","commitment":"<64 hex>"}
/// {"type":"sas_nonce","v":1,"attempt":"sas_…","mac_link":"<x963 b64>","mac_nonce":"<32 bytes b64>"}
/// {"type":"sas_reveal","v":1,"attempt":"sas_…","phone_link":"<x963 b64>","phone_approve":"<x963 b64>","phone_nonce":"<32 bytes b64>"}
/// ```
///
/// Peers that predate them never send `sas_commit` (an old iPhone) or never answer it (an old
/// Mac), and the other side then shows no number at all: confirming needs a finished exchange.
public struct SASCommit: Codable, Equatable, Sendable {
	public var attempt: String
	public var commitment: String

	public init(attempt: String, commitment: String) {
		self.attempt = attempt
		self.commitment = commitment
	}
}

public struct SASNonce: Codable, Equatable, Sendable {
	public var attempt: String
	public var mac_link: String
	public var mac_nonce: String

	public init(attempt: String, mac_link: String, mac_nonce: String) {
		self.attempt = attempt
		self.mac_link = mac_link
		self.mac_nonce = mac_nonce
	}
}

public struct SASReveal: Codable, Equatable, Sendable {
	public var attempt: String
	public var phone_link: String
	public var phone_approve: String
	public var phone_nonce: String

	public init(attempt: String, phone_link: String, phone_approve: String, phone_nonce: String) {
		self.attempt = attempt
		self.phone_link = phone_link
		self.phone_approve = phone_approve
		self.phone_nonce = phone_nonce
	}
}

public enum SASError: Error, Equatable, Sendable {
	case malformed(String)
	/// A `sas_reveal` (or `sas_nonce`) with no `sas_commit` recorded for it.
	case noCommitment
	/// For another attempt than the one in progress; the attempt is left as it was.
	case attemptMismatch
	/// The reveal does not open the commitment. The attempt is failed for good.
	case commitmentMismatch
	/// The keys in the message are not the ones the account lists for the sender. The attempt is
	/// failed for good.
	case keysMismatch
	/// The attempt already has its number, or already failed: a new attempt is needed.
	case finished
}

public enum SASAttempt {
	/// `sas_` + 24 base32 characters.
	public static func newID() -> String { LinkCrypto.newPrefixedID("sas") }

	public static func isValidID(_ value: String) -> Bool { LinkCrypto.isValidPrefixedID(value, prefix: "sas") }

	static func nonce(_ base64: String) throws -> Data {
		guard let data = Data(base64Encoded: base64), data.count == SafetyNumber.nonceLength else {
			throw SASError.malformed("nonce")
		}
		return data
	}

	static func isValidCommitment(_ value: String) -> Bool {
		value.utf8.count == 64 && value.utf8.allSatisfy {
			(UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
		}
	}
}

/// The phone's side of one attempt: commit, take the Mac's nonce once, reveal. The phone nonce
/// stays in memory and is only sent in the reveal, after the Mac's nonce arrived.
public struct SASInitiator: Sendable {
	public enum Stage: Equatable, Sendable {
		case committed, complete, failed
	}

	public let attempt: String
	public let phoneID: String
	public let macID: String
	public let phoneLink: LinkPublicKey
	public let phoneApprove: LinkPublicKey
	public let commitment: String
	private let phoneNonce: Data
	public private(set) var stage: Stage = .committed
	/// The Mac link key the number covers (the one the account lists, equal to the nonce's).
	public private(set) var macLink: LinkPublicKey?
	public private(set) var number: String?

	public init(
		phoneID: String, macID: String, phoneLink: LinkPublicKey, phoneApprove: LinkPublicKey,
		attempt: String = SASAttempt.newID(), phoneNonce: Data = LinkCrypto.randomBytes(SafetyNumber.nonceLength)
	) {
		self.attempt = attempt
		self.phoneID = phoneID
		self.macID = macID
		self.phoneLink = phoneLink
		self.phoneApprove = phoneApprove
		self.phoneNonce = phoneNonce
		commitment = SafetyNumber.commitment(
			attempt: attempt, phoneID: phoneID, macID: macID, phoneLink: phoneLink, phoneApprove: phoneApprove,
			phoneNonce: phoneNonce)
	}

	public var commit: SASCommit { SASCommit(attempt: attempt, commitment: commitment) }

	/// The Mac's nonce, from the Mac whose link key the account lists as `listedMacLink`. Only the
	/// first one counts: after it (or a refused one) the attempt is over. Returns the reveal to send;
	/// `number` is set.
	public mutating func receive(_ nonce: SASNonce, listedMacLink: LinkPublicKey) throws -> SASReveal {
		guard nonce.attempt == attempt else { throw SASError.attemptMismatch }
		guard stage == .committed else { throw SASError.finished }
		stage = .failed
		let macNonce = try SASAttempt.nonce(nonce.mac_nonce)
		guard let announced = try? LinkPublicKey(x963Base64: nonce.mac_link) else { throw SASError.malformed("mac_link") }
		guard announced == listedMacLink else { throw SASError.keysMismatch }
		macLink = listedMacLink
		number = SafetyNumber.compute(
			attempt: attempt, phoneID: phoneID, macID: macID, macLink: listedMacLink, phoneLink: phoneLink,
			phoneApprove: phoneApprove, phoneNonce: phoneNonce, macNonce: macNonce)
		stage = .complete
		return SASReveal(
			attempt: attempt, phone_link: phoneLink.x963Base64, phone_approve: phoneApprove.x963Base64,
			phone_nonce: phoneNonce.base64EncodedString())
	}
}

/// The Mac's side of one attempt: record the commitment, answer with a fresh nonce, then accept
/// exactly one reveal that opens the commitment with the keys the account lists for the phone.
/// Codable so the helper keeps it across restarts (nothing in it is secret).
public struct SASResponder: Codable, Equatable, Sendable {
	public enum Stage: String, Codable, Sendable {
		case awaitingReveal = "awaiting_reveal"
		case complete
		case failed
	}

	public let attempt: String
	public let commitment: String
	public let mac_nonce: String
	/// When the commitment arrived (Unix seconds, the caller's clock).
	public let started_at: Int
	public private(set) var stage: Stage
	/// Filled in by a reveal that opened the commitment: the keys the number covers.
	public private(set) var phone_link: String?
	public private(set) var phone_approve: String?
	public private(set) var mac_link: String?
	public private(set) var number: String?
	/// Why the attempt failed, for the log and the card.
	public private(set) var failure: String?

	public init(
		commit: SASCommit, startedAt: Int, macNonce: Data = LinkCrypto.randomBytes(SafetyNumber.nonceLength)
	) throws {
		guard SASAttempt.isValidID(commit.attempt) else { throw SASError.malformed("attempt") }
		guard SASAttempt.isValidCommitment(commit.commitment) else { throw SASError.malformed("commitment") }
		guard macNonce.count == SafetyNumber.nonceLength else { throw SASError.malformed("nonce") }
		attempt = commit.attempt
		commitment = commit.commitment
		mac_nonce = macNonce.base64EncodedString()
		started_at = startedAt
		stage = .awaitingReveal
	}

	public func nonceMessage(macLink: LinkPublicKey) -> SASNonce {
		SASNonce(attempt: attempt, mac_link: macLink.x963Base64, mac_nonce: mac_nonce)
	}

	/// The phone's reveal. `listedLink` / `listedApprove` are the keys the account lists for the
	/// sender (what the Mac pins), `macLink` this Mac's own. Any refusal other than
	/// `attemptMismatch` ends the attempt: no second reveal is ever tried against it.
	public mutating func receive(
		_ reveal: SASReveal, phoneID: String, macID: String, macLink: LinkPublicKey, listedLink: LinkPublicKey,
		listedApprove: LinkPublicKey?
	) throws -> String {
		guard reveal.attempt == attempt else { throw SASError.attemptMismatch }
		guard stage == .awaitingReveal else { throw SASError.finished }
		do {
			guard let link = try? LinkPublicKey(x963Base64: reveal.phone_link),
				let approve = try? LinkPublicKey(x963Base64: reveal.phone_approve)
			else { throw SASError.malformed("keys") }
			let phoneNonce = try SASAttempt.nonce(reveal.phone_nonce)
			let opened = SafetyNumber.commitment(
				attempt: attempt, phoneID: phoneID, macID: macID, phoneLink: link, phoneApprove: approve,
				phoneNonce: phoneNonce)
			guard opened == commitment else { throw SASError.commitmentMismatch }
			guard link == listedLink, approve == listedApprove else { throw SASError.keysMismatch }
			let macNonce = try SASAttempt.nonce(mac_nonce)
			let number = SafetyNumber.compute(
				attempt: attempt, phoneID: phoneID, macID: macID, macLink: macLink, phoneLink: link, phoneApprove: approve,
				phoneNonce: phoneNonce, macNonce: macNonce)
			phone_link = link.x963Base64
			phone_approve = approve.x963Base64
			mac_link = macLink.x963Base64
			self.number = number
			stage = .complete
			return number
		} catch {
			stage = .failed
			failure = "\(error)"
			throw error
		}
	}

	/// The number, when this attempt finished for exactly these keys (X9.63 base64).
	public func number(phoneLink: String, phoneApprove: String, macLink: LinkPublicKey?) -> String? {
		guard stage == .complete, phone_link == phoneLink, phone_approve == phoneApprove,
			let macLink, mac_link == macLink.x963Base64
		else { return nil }
		return number
	}
}
