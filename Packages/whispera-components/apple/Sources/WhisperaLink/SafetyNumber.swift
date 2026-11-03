import CryptoKit
import Foundation

/// The short code the owner compares on the Mac and the iPhone before the Mac trusts a phone
/// that joined through the account (and before the phone trusts that Mac).
///
/// Both sides get the other's keys from the backend, so the number alone cannot stop a backend
/// that hands each side substituted keys: with 12 digits (about 40 bits) it could try a million
/// keys per side until the two screens agree. So the number also covers two random nonces, and
/// the keys are fixed by a commitment before either side sees the other's nonce
/// (`SASInitiator` / `SASResponder`, SAS-with-commitment as in ZRTP):
///
/// 1. phone → Mac `sas_commit`: `commitment(attempt, ids, phone link, phone approve, phone nonce)`
/// 2. Mac → phone `sas_nonce`: its link key and a fresh Mac nonce, only after recording 1
/// 3. phone → Mac `sas_reveal`: its keys and the phone nonce, which must open the commitment
///
/// A substituting backend has to fix the keys and nonce it shows the Mac before it learns the
/// Mac's nonce, and the Mac key and nonce it shows the phone before it learns the phone's: one
/// guess per attempt, 2^-40.
///
/// The phone's agreement key is covered through its `KEMKeyRecord`, which its link key signs;
/// the Mac's the same way.
public enum SafetyNumber {
	public static let nonceLength = 32

	/// `hex(sha256("WL2-SAS-COMMIT\n" ‖ fields))`, each field length-prefixed: attempt, phone id,
	/// Mac id, phone link x963, phone approve x963, phone nonce.
	public static func commitment(
		attempt: String, phoneID: String, macID: String, phoneLink: LinkPublicKey, phoneApprove: LinkPublicKey,
		phoneNonce: Data
	) -> String {
		LinkCrypto.hex(
			digest(
				"WL2-SAS-COMMIT\n",
				[Data(attempt.utf8), Data(phoneID.utf8), Data(macID.utf8), phoneLink.x963, phoneApprove.x963, phoneNonce]))
	}

	/// `sha256("WL2-SAS\n" ‖ fields)`, each field length-prefixed: attempt, phone id, Mac id, Mac
	/// link x963, phone link x963, phone approve x963, phone nonce, Mac nonce; the first 8 bytes
	/// big-endian mod 10^12, as `1234 5678 9012`.
	public static func compute(
		attempt: String, phoneID: String, macID: String, macLink: LinkPublicKey, phoneLink: LinkPublicKey,
		phoneApprove: LinkPublicKey, phoneNonce: Data, macNonce: Data
	) -> String {
		let hash = digest(
			"WL2-SAS\n",
			[
				Data(attempt.utf8), Data(phoneID.utf8), Data(macID.utf8), macLink.x963, phoneLink.x963, phoneApprove.x963,
				phoneNonce, macNonce,
			])
		let value = hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_000_000
		let digits = String(format: "%012llu", value)
		var groups: [Substring] = []
		var rest = Substring(digits)
		while !rest.isEmpty {
			groups.append(rest.prefix(4))
			rest = rest.dropFirst(4)
		}
		return groups.joined(separator: " ")
	}

	private static func digest(_ domain: String, _ fields: [Data]) -> Data {
		var input = Data(domain.utf8)
		for field in fields {
			var length = UInt32(field.count).bigEndian
			input.append(Data(bytes: &length, count: 4))
			input.append(field)
		}
		return Data(SHA256.hash(data: input))
	}
}
