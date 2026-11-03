import Foundation
import Security

/// Where the Mac approve key's identity (device id, the enclave's wrapped key handle, the public
/// key) is kept between launches.
public protocol MacApproveKeyStoring: Sendable {
	func load() throws -> Data?
	func save(_ data: Data) throws
	func delete() throws
}

public struct MacApproveKeyStoreError: Error, Equatable, CustomStringConvertible {
	public let status: OSStatus
	public var description: String { "keychain error \(status)" }
}

/// One generic-password Keychain item, `WhenUnlockedThisDeviceOnly`: never synced, never restored
/// to another Mac.
///
/// The data protection keychain first. It needs a keychain access group, which only a program
/// signed with `keychain-access-groups` or `com.apple.application-identifier` has, and on macOS
/// both need a provisioning profile; a Developer ID build without one gets
/// `errSecMissingEntitlement` there. Then the item goes in the login keychain instead, whose
/// access list trusts only the app that created it, so another program the user runs cannot read
/// it without a keychain prompt.
public struct KeychainMacApproveKeyStore: MacApproveKeyStoring {
	public let service: String
	public let account: String
	public let accessGroup: String?

	public init(
		service: String = "com.whispera.link.mac-approve-key", account: String = "approve-key",
		accessGroup: String? = nil
	) {
		self.service = service
		self.account = account
		self.accessGroup = accessGroup
	}

	private func query(dataProtection: Bool) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		if dataProtection {
			query[kSecUseDataProtectionKeychain as String] = true
			if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
		}
		return query
	}

	public func load() throws -> Data? {
		for dataProtection in [true, false] {
			var query = query(dataProtection: dataProtection)
			query[kSecReturnData as String] = true
			query[kSecMatchLimit as String] = kSecMatchLimitOne
			var result: CFTypeRef?
			let status = SecItemCopyMatching(query as CFDictionary, &result)
			switch status {
			case errSecSuccess: return result as? Data
			case errSecItemNotFound, errSecMissingEntitlement: continue
			default: throw MacApproveKeyStoreError(status: status)
			}
		}
		return nil
	}

	public func save(_ data: Data) throws {
		var status = add(data, dataProtection: true)
		if status == errSecMissingEntitlement { status = add(data, dataProtection: false) }
		guard status == errSecSuccess else { throw MacApproveKeyStoreError(status: status) }
	}

	private func add(_ data: Data, dataProtection: Bool) -> OSStatus {
		let match = query(dataProtection: dataProtection)
		let deleted = SecItemDelete(match as CFDictionary)
		if deleted == errSecMissingEntitlement { return deleted }
		var attributes = match
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		return SecItemAdd(attributes as CFDictionary, nil)
	}

	public func delete() throws {
		for dataProtection in [true, false] {
			let status = SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
			guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
				throw MacApproveKeyStoreError(status: status)
			}
		}
	}
}
