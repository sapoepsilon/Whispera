import CryptoKit
import Foundation
import Security

/// RFC 7636 proof key, S256 only (`plain` is never sent).
public struct PKCE: Equatable, Sendable {
	/// 43–128 characters of `[A-Z a-z 0-9 - . _ ~]`.
	public let verifier: String
	/// `BASE64URL-NOPAD(SHA256(ASCII(verifier)))`.
	public let challenge: String
	public static let method = "S256"

	/// A fresh verifier: 32 random bytes, base64url — 43 characters.
	public init() {
		self.init(unchecked: OIDCRandom.base64URL(bytes: 32))
	}

	/// A known verifier (tests, the RFC 7636 appendix B vector).
	public init(verifier: String) throws {
		let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
		guard (43...128).contains(verifier.count), verifier.allSatisfy({ allowed.contains($0) }) else {
			throw AccountError.invalidPKCEVerifier
		}
		self.init(unchecked: verifier)
	}

	private init(unchecked verifier: String) {
		self.verifier = verifier
		challenge = Self.challenge(for: verifier)
	}

	public static func challenge(for verifier: String) -> String {
		OIDCRandom.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
	}
}

enum OIDCRandom {
	static func bytes(_ count: Int) -> Data {
		var data = Data(count: count)
		let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
		precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
		return data
	}

	static func base64URL(bytes count: Int) -> String {
		base64URL(bytes(count))
	}

	static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	static func decodeBase64URL(_ string: String) -> Data? {
		var b64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while b64.count % 4 != 0 { b64 += "=" }
		return Data(base64Encoded: b64)
	}
}
