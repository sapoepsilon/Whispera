import Foundation
import Security
import WhisperaDictation

public enum AuthTokenStoreError: LocalizedError, Equatable {
	case unexpectedStatus(OSStatus)

	public var errorDescription: String? {
		switch self {
		case .unexpectedStatus(let status):
			let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
			return "Keychain error: \(message)"
		}
	}
}

/// The Whispera session token, in the Keychain.
///
/// Same hygiene as a provider key: device-only, read at request time, dropped
/// after use, never written to UserDefaults or a log. Its own service, so an
/// auth token and a BYOK key can never be confused for one another.
public struct AuthTokenStore: Sendable {
	public static let shared = AuthTokenStore()

	private let service: String
	private let account = "session"

	public init(service: String = "com.whispera.clerk") {
		self.service = service
	}

	public func save(_ token: String) throws {
		try? delete()
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecValueData as String: Data(token.utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		]
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else { throw AuthTokenStoreError.unexpectedStatus(status) }
	}

	public func load() throws -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw AuthTokenStoreError.unexpectedStatus(status) }
		guard let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	public func delete() throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw AuthTokenStoreError.unexpectedStatus(status)
		}
	}

	/// The store as the dictation package wants credentials: minted per connect,
	/// so a token that was replaced between two sessions is picked up without any
	/// refresh wiring on the host's side.
	///
	/// This is the seam. Everywhere the app used to take an `AuthTokenStore` as a
	/// default initialiser argument — the streaming and batch transcribers both
	/// did — it takes a `DictationCredentialProvider` instead, and this is the
	/// one place that knows the two are related. A missing token yields an empty
	/// credential rather than throwing: a self-hosted proxy on a trusted network
	/// may not want one, and refusing to connect would make the client harder to
	/// bring up than the server it talks to.
	public var credentialProvider: any DictationCredentialProvider {
		let store = self
		return RefreshingCredential {
			let token = ((try? store.load()) ?? nil) ?? ""
			return token.isEmpty ? .none : .bearer(token)
		}
	}
}
