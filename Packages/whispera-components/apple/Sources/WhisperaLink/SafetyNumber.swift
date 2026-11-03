import CryptoKit
import Foundation

/// The short code the owner compares on the Mac and the iPhone before the Mac trusts a phone
/// that joined through the account (and before the phone trusts that Mac).
///
/// Both sides compute it from the keys *they* were given: the Mac's link key and the phone's
/// link and approve keys. A backend that hands either side a substituted key makes the two
/// screens show different numbers. The phone's agreement key is covered through its
/// `KEMKeyRecord`, which its link key signs; the Mac's the same way.
///
/// `sha256("WL1-SAS\n" ‖ mac link x963 ‖ phone link x963 ‖ phone approve x963)`, first 8
/// bytes big-endian mod 10^12, as `1234 5678 9012` (about 40 bits).
public enum SafetyNumber {
	public static func compute(macLink: LinkPublicKey, phoneLink: LinkPublicKey, phoneApprove: LinkPublicKey?)
		-> String
	{
		var input = Data("WL1-SAS\n".utf8)
		input.append(macLink.x963)
		input.append(phoneLink.x963)
		input.append(phoneApprove?.x963 ?? Data())
		let digest = Array(SHA256.hash(data: input))
		let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_000_000
		let digits = String(format: "%012llu", value)
		var groups: [Substring] = []
		var rest = Substring(digits)
		while !rest.isEmpty {
			groups.append(rest.prefix(4))
			rest = rest.dropFirst(4)
		}
		return groups.joined(separator: " ")
	}
}
