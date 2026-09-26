import Foundation
import Security

protocol PostProcessingSecretStore: Sendable {
	func apiKey(for providerID: String) throws -> String?
	func setAPIKey(_ key: String?, for providerID: String) throws
}

enum KeychainError: LocalizedError, Equatable {
	case unexpectedStatus(OSStatus)
	case invalidData

	var errorDescription: String? {
		switch self {
		case .unexpectedStatus(let status):
			let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
			return "Keychain error \(status): \(message)"
		case .invalidData:
			return "Keychain item could not be decoded"
		}
	}
}

/// Stores provider API keys as generic passwords in the login Keychain, one item per provider.
struct KeychainSecretStore: PostProcessingSecretStore {
	static let defaultService = "com.macwhisper.app.post-processing"

	let service: String

	init(service: String = KeychainSecretStore.defaultService) {
		self.service = service
	}

	func apiKey(for providerID: String) throws -> String? {
		var query = baseQuery(for: providerID)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
				throw KeychainError.invalidData
			}
			return key
		case errSecItemNotFound:
			return nil
		default:
			throw KeychainError.unexpectedStatus(status)
		}
	}

	func setAPIKey(_ key: String?, for providerID: String) throws {
		let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !trimmed.isEmpty else {
			let status = SecItemDelete(baseQuery(for: providerID) as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else {
				throw KeychainError.unexpectedStatus(status)
			}
			return
		}

		let data = Data(trimmed.utf8)
		let updateStatus = SecItemUpdate(
			baseQuery(for: providerID) as CFDictionary,
			[kSecValueData as String: data] as CFDictionary)
		switch updateStatus {
		case errSecSuccess:
			return
		case errSecItemNotFound:
			var addQuery = baseQuery(for: providerID)
			addQuery[kSecValueData as String] = data
			addQuery[kSecAttrLabel as String] = "Whispera post-processing API key (\(providerID))"
			addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
			let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
			guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
		default:
			throw KeychainError.unexpectedStatus(updateStatus)
		}
	}

	private func baseQuery(for providerID: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: providerID,
		]
	}
}
