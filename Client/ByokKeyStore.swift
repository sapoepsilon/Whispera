// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Security

/// Provider whose API key the user can bring (BYOK).
enum ProviderId: String, CaseIterable, Sendable {
	case openai
	case anthropic

	var displayName: String {
		switch self {
		case .openai: return "OpenAI"
		case .anthropic: return "Anthropic"
		}
	}
}

enum ByokKeyStoreError: LocalizedError {
	case unexpectedStatus(OSStatus)

	var errorDescription: String? {
		switch self {
		case .unexpectedStatus(let status):
			let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
			return "Keychain error: \(message)"
		}
	}
}

/// Stores BYOK provider keys in the macOS Keychain.
///
/// Keys are written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they
/// never sync to iCloud and never restore onto another device. The key material
/// is read at request time and dropped — it is never persisted to UserDefaults,
/// app-support files, or logs. See WHI-40.
struct ByokKeyStore {
	static let shared = ByokKeyStore()

	/// One Keychain service per concern keeps BYOK keys isolated from the auth token.
	private let service: String

	init(service: String = "com.whispera.byok") {
		self.service = service
	}

	/// Keychain account for the optional Local-mode server bearer key. Deliberately
	/// not a `ProviderId` so it can never surface as a BYOK provider.
	private static let localServerAccount = "local-server"

	func save(provider: ProviderId, key: String) throws {
		try save(account: provider.rawValue, key: key)
	}

	func load(provider: ProviderId) throws -> String? {
		try load(account: provider.rawValue)
	}

	func delete(provider: ProviderId) throws {
		try delete(account: provider.rawValue)
	}

	// MARK: - Local server key

	func saveLocalServerKey(_ key: String) throws {
		try save(account: Self.localServerAccount, key: key)
	}

	func loadLocalServerKey() throws -> String? {
		try load(account: Self.localServerAccount)
	}

	func deleteLocalServerKey() throws {
		try delete(account: Self.localServerAccount)
	}

	func hasLocalServerKey() -> Bool {
		((try? loadLocalServerKey()) ?? nil)?.isEmpty == false
	}

	// MARK: - Keychain primitives

	private func save(account: String, key: String) throws {
		let data = Data(key.utf8)

		// SecItemUpdate can't change kSecAttrAccessible, so delete-then-add keeps
		// the accessibility flag authoritative on every write.
		try? delete(account: account)

		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		]

		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else { throw ByokKeyStoreError.unexpectedStatus(status) }
	}

	private func load(account: String) throws -> String? {
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
		guard status == errSecSuccess else { throw ByokKeyStoreError.unexpectedStatus(status) }
		guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
			return nil
		}
		return key
	}

	private func delete(account: String) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw ByokKeyStoreError.unexpectedStatus(status)
		}
	}

	/// Returns providers that have a key stored WITHOUT loading the key material.
	func providers() throws -> [ProviderId] {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecReturnAttributes as String: true,
			kSecMatchLimit as String: kSecMatchLimitAll,
		]

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess else { throw ByokKeyStoreError.unexpectedStatus(status) }
		guard let items = result as? [[String: Any]] else { return [] }

		return items.compactMap { item in
			(item[kSecAttrAccount as String] as? String).flatMap(ProviderId.init(rawValue:))
		}
	}
}
