import Foundation
import Security

public enum OpenAIKeyStoreError: LocalizedError, Equatable {
	case unexpectedStatus(OSStatus)

	public var errorDescription: String? {
		switch self {
		case .unexpectedStatus(let status):
			let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
			return "Keychain error: \(message)"
		}
	}
}

/// Stores per-server API keys in the Keychain.
///
/// Keyed by an opaque server id rather than by a provider enum, because the
/// enum was the thing that made "any OpenAI-compatible cloud" unreachable: a
/// closed set of two providers cannot hold a key for the third endpoint a user
/// stands up. An id is whatever the host calls a server entry.
///
/// Keys are written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they
/// never sync to iCloud and never restore onto another device, and they are read
/// at request time and dropped — never to UserDefaults, a support file, or a log.
public struct OpenAIKeyStore: Sendable {
	public static let shared = OpenAIKeyStore()

	private let service: String

	public init(service: String = "com.whispera.byok") {
		self.service = service
	}

	public func save(serverId: String, key: String) throws {
		// SecItemUpdate cannot change kSecAttrAccessible, so delete-then-add keeps
		// the accessibility flag authoritative on every write.
		try? delete(serverId: serverId)

		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: serverId,
			kSecValueData as String: Data(key.utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		]
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else { throw OpenAIKeyStoreError.unexpectedStatus(status) }
	}

	public func load(serverId: String) throws -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: serverId,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw OpenAIKeyStoreError.unexpectedStatus(status) }
		guard let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	public func delete(serverId: String) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: serverId,
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw OpenAIKeyStoreError.unexpectedStatus(status)
		}
	}

	public func hasKey(serverId: String) -> Bool {
		((try? load(serverId: serverId)) ?? nil)?.isEmpty == false
	}

	/// Which servers have a key, WITHOUT loading any key material.
	public func serverIds() throws -> [String] {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecReturnAttributes as String: true,
			kSecMatchLimit as String: kSecMatchLimitAll,
		]

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess else { throw OpenAIKeyStoreError.unexpectedStatus(status) }
		guard let items = result as? [[String: Any]] else { return [] }
		return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
	}

	/// The key as the client wants it: a closure read at request time.
	public func keyProvider(serverId: String) -> @Sendable () -> String? {
		let store = self
		return { (try? store.load(serverId: serverId)) ?? nil }
	}
}
