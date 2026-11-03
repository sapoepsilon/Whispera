import Foundation
import WhisperaLink

/// A cross-signature between devices of one account: `voucher_id`, a Mac the owner approved,
/// states that `subject_id` with exactly these keys is the owner's too, until `expires_at`.
///
/// Only a Mac vouches, and only for what the owner established on that Mac with a deliberate
/// act: a phone whose safety number was compared there (`safety_number`), or a Mac the owner
/// approved there with Touch ID (`owner_approval`). A device accepted on a vouch never vouches
/// for anything in turn (no chains). The account backend lists keys but cannot make a vouch:
/// only the voucher's link key signs one, and a receiver checks it against the key *it* pinned
/// for the voucher when the owner approved that Mac, never the backend's copy.
///
/// Signed bytes, one field per line, no trailing newline:
/// `WL1-VOUCH\n2\n<voucher>\n<subject>\n<platform>\n<link>\n<approve or ->\n<kem>\n<evidence>\n<issued_at>\n<expires_at>`
public struct DeviceVouch: Codable, Equatable, Hashable, Sendable {
	public static let version = 2
	public static let context = "WL1-VOUCH"
	/// How long a vouch lasts; the voucher re-issues it while the trust holds.
	public static let lifetime = 30 * 86_400
	/// The longest lifetime a receiver accepts.
	public static let maxLifetime = 31 * 86_400

	/// The owner's deliberate act on the voucher.
	public enum Evidence: String, Codable, Sendable, CaseIterable {
		/// The owner compared the phone's safety number on the voucher and confirmed it.
		case safetyNumber = "safety_number"
		/// The owner approved the Mac on the voucher (Touch ID), after a tailnet proof.
		case ownerApproval = "owner_approval"
	}

	public var v: Int
	public var voucher_id: String
	public var subject_id: String
	public var subject_platform: String
	public var subject_link_pubkey: String
	public var subject_approve_pubkey: String?
	public var subject_kem_pubkey: String
	public var evidence: String
	public var issued_at: Int
	public var expires_at: Int
	/// DER ECDSA P-256 over `signedBytes`, base64.
	public var signature: String

	public var signedBytes: Data {
		let lines: [String] = [
			Self.context, String(v), voucher_id, subject_id, subject_platform, subject_link_pubkey,
			subject_approve_pubkey ?? "-", subject_kem_pubkey, evidence, String(issued_at), String(expires_at),
		]
		return Data(lines.joined(separator: "\n").utf8)
	}

	public static func issue(
		voucherID: String, key: LinkSigningKey, for subject: TrustedDevice, evidence: Evidence, issuedAt: Int,
		lifetime: Int = DeviceVouch.lifetime
	) throws -> DeviceVouch {
		var vouch = DeviceVouch(
			v: version, voucher_id: voucherID, subject_id: subject.id, subject_platform: subject.platform.rawValue,
			subject_link_pubkey: subject.linkKey.x963Base64, subject_approve_pubkey: subject.approveKey?.x963Base64,
			subject_kem_pubkey: subject.agreementKey.x963Base64, evidence: evidence.rawValue, issued_at: issuedAt,
			expires_at: issuedAt + lifetime, signature: "")
		vouch.signature = try key.sign(vouch.signedBytes).base64EncodedString()
		return vouch
	}

	/// Every field well formed: valid ids, no line breaks that could shift the signed lines, a
	/// known evidence and version, a lifetime of at most `maxLifetime`.
	public var isWellFormed: Bool {
		guard v == Self.version, LinkCrypto.isValidDeviceID(voucher_id), LinkCrypto.isValidDeviceID(subject_id),
			voucher_id != subject_id, Platform(rawValue: subject_platform) != nil,
			Evidence(rawValue: evidence) != nil, expires_at > issued_at, expires_at - issued_at <= Self.maxLifetime
		else { return false }
		let fields = [subject_link_pubkey, subject_approve_pubkey ?? "-", subject_kem_pubkey]
		return fields.allSatisfy { !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") }
	}

	public func isSigned(by key: LinkPublicKey) -> Bool {
		guard isWellFormed, let der = Data(base64Encoded: signature), !der.isEmpty else { return false }
		return key.isValidSignature(der, for: signedBytes)
	}

	public func covers(_ device: TrustedDevice) -> Bool {
		subject_id == device.id && subject_platform == device.platform.rawValue
			&& subject_link_pubkey == device.linkKey.x963Base64
			&& subject_approve_pubkey == device.approveKey?.x963Base64
			&& subject_kem_pubkey == device.agreementKey.x963Base64
	}

	public func isCurrent(now: Int) -> Bool {
		issued_at <= now + VouchTrust.futureSkew && now < expires_at
	}
}

/// Which listed devices a device may trust through vouches.
public enum VouchTrust {
	/// How far in the future an `issued_at` may be (clock skew between devices).
	public static let futureSkew = 600
	/// The most vouches kept from one voucher.
	public static let maxPerVoucher = 128

	/// The subjects accepted on a vouch, each with the vouch that let it in.
	///
	/// - `roots`: Macs the owner approved (or confirmed) on this device. Only a root vouches, and
	///   only while the account lists it as a Mac, unrevoked, with exactly the pinned keys.
	/// - `account`: the account's devices, classified *without* pins.
	/// - A vouch counts when its voucher is a root, it is current, its signature verifies under
	///   the voucher's pinned key, and the subject is listed now with exactly the vouched keys.
	///   This device and `excluded` subjects (the owner said no) are never accepted. Depth 1: an
	///   accepted subject is never a voucher.
	public static func accepted(
		roots: [String: PinnedDeviceKeys], account: AccountDevices, vouches: [DeviceVouch], selfID: String?,
		now: Int, excluded: Set<String> = []
	) -> [String: DeviceVouch] {
		var listed: [String: TrustedDevice] = [:]
		for device in account.peers { listed[device.id] = device }
		var vouchers: [String: LinkPublicKey] = [:]
		for mac in account.macs where mac.id != selfID {
			if let pin = roots[mac.id], pin.matches(mac) { vouchers[mac.id] = mac.linkKey }
		}
		var accepted: [String: DeviceVouch] = [:]
		for vouch in vouches {
			let subject = vouch.subject_id
			guard subject != selfID, !excluded.contains(subject), let key = vouchers[vouch.voucher_id],
				let device = listed[subject], vouch.isCurrent(now: now), vouch.covers(device), vouch.isSigned(by: key)
			else { continue }
			if let existing = accepted[subject], existing.expires_at >= vouch.expires_at { continue }
			accepted[subject] = vouch
		}
		return accepted
	}
}
