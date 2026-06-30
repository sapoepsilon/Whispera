// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Security

/// Stores the Whispera auth token (Clerk session JWT or a dev token) in the
/// Keychain with the same hygiene as BYOK keys: device-only, read at request
/// time, dropped after use, never written to UserDefaults or logs. See WHI-45.
struct AuthTokenStore {
	static let shared = AuthTokenStore()

	private let service: String
	private let account = "session"

	init(service: String = "com.whispera.clerk") {
		self.service = service
	}

	func save(_ token: String) throws {
		try? delete()
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecValueData as String: Data(token.utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
		]
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else { throw ByokKeyStoreError.unexpectedStatus(status) }
	}

	func load() throws -> String? {
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
		guard let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	func delete() throws {
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
}
