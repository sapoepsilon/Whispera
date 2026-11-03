import Foundation
import Security

/// Where the signed-in credential lives between launches.
public protocol AccountTokenStore: Sendable {
	func load() throws -> AccountCredential?
	func save(_ credential: AccountCredential) throws
	func clear() throws
}

/// One generic-password Keychain item holding the credential as JSON,
/// `AfterFirstUnlockThisDeviceOnly` — readable by a background helper, never synced
/// or restored to another device.
public struct KeychainAccountTokenStore: AccountTokenStore {
	public let service: String
	public let account: String
	public let accessGroup: String?
	public let useDataProtectionKeychain: Bool

	/// - Parameters:
	///   - service: each host picks its own (e.g. its bundle id + `.account`).
	///   - accessGroup: share the item with an app extension or helper that has the
	///     same keychain access group; nil for the app's default group.
	///   - useDataProtectionKeychain: macOS only — needs a signed app with a keychain
	///     access group; leave `false` for an unsigned helper or tests.
	public init(
		service: String, account: String = "account-credential", accessGroup: String? = nil,
		useDataProtectionKeychain: Bool = false
	) {
		self.service = service
		self.account = account
		self.accessGroup = accessGroup
		self.useDataProtectionKeychain = useDataProtectionKeychain
	}

	private var baseQuery: [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
		#if os(macOS)
			if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
		#endif
		return query
	}

	public func load() throws -> AccountCredential? {
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw AccountError.keychain(status) }
		// An unreadable item (older format) is treated as signed out, not as an error.
		return try? JSONDecoder().decode(AccountCredential.self, from: data)
	}

	public func save(_ credential: AccountCredential) throws {
		let data = try JSONEncoder().encode(credential)
		SecItemDelete(baseQuery as CFDictionary)
		var attributes = baseQuery
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(attributes as CFDictionary, nil)
		guard status == errSecSuccess else { throw AccountError.keychain(status) }
	}

	public func clear() throws {
		let status = SecItemDelete(baseQuery as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
	}
}

/// For tests and previews.
public final class InMemoryAccountTokenStore: AccountTokenStore, @unchecked Sendable {
	private let lock = NSLock()
	private var credential: AccountCredential?
	/// How many times `save` ran — lets a test see a refresh was persisted.
	public private(set) var saveCount = 0

	public init(_ credential: AccountCredential? = nil) {
		self.credential = credential
	}

	public func load() throws -> AccountCredential? {
		lock.lock()
		defer { lock.unlock() }
		return credential
	}

	public func save(_ credential: AccountCredential) throws {
		lock.lock()
		defer { lock.unlock() }
		self.credential = credential
		saveCount += 1
	}

	public func clear() throws {
		lock.lock()
		defer { lock.unlock() }
		credential = nil
	}
}
