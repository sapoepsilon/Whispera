import CryptoKit
import Darwin
import Foundation
import Security

/// Holds the secret that signs script approvals. It lives in the Keychain so a process that can
/// only write Whispera's preferences (`defaults write`) cannot mint a valid approval.
protocol ScriptApprovalKeyStore: Sendable {
	func key(createIfMissing: Bool) throws -> SymmetricKey?
}

struct KeychainScriptApprovalKeyStore: ScriptApprovalKeyStore {
	static let defaultService = "com.macwhisper.app.insertion-script"
	private static let account = "approval-key"

	let service: String

	init(service: String = KeychainScriptApprovalKeyStore.defaultService) {
		self.service = service
	}

	func key(createIfMissing: Bool) throws -> SymmetricKey? {
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let data = result as? Data, data.count == 32 else { throw KeychainError.invalidData }
			return SymmetricKey(data: data)
		case errSecItemNotFound:
			guard createIfMissing else { return nil }
			let key = SymmetricKey(size: .bits256)
			var add = baseQuery
			add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
			add[kSecAttrLabel as String] = "Whispera insertion script approval key"
			add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			let addStatus = SecItemAdd(add as CFDictionary, nil)
			guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
			return key
		default:
			throw KeychainError.unexpectedStatus(status)
		}
	}

	private var baseQuery: [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: Self.account,
		]
	}
}

/// Identity of a script file at the moment the user chose it. Any edit, replacement or move
/// changes it, and so invalidates the approval.
struct ScriptFingerprint: Equatable, Sendable {
	let path: String
	let device: Int64
	let inode: UInt64
	let size: Int64
	let modifiedSeconds: Int
	let modifiedNanoseconds: Int
	let owner: UInt32
	let mode: UInt16

	static func read(path: String) throws -> ScriptFingerprint {
		var info = stat()
		guard stat(path, &info) == 0 else { throw ExternalScriptError.notExecutable(path) }
		return ScriptFingerprint(
			path: path,
			device: Int64(info.st_dev),
			inode: UInt64(info.st_ino),
			size: Int64(info.st_size),
			modifiedSeconds: info.st_mtimespec.tv_sec,
			modifiedNanoseconds: info.st_mtimespec.tv_nsec,
			owner: info.st_uid,
			mode: UInt16(info.st_mode)
		)
	}

	var canonical: String {
		"v1|\(path)|\(device)|\(inode)|\(size)|\(modifiedSeconds).\(modifiedNanoseconds)|\(owner)|\(mode)"
	}
}

enum ScriptApproval {
	/// Called only from the file picker in Settings. Returns the value to store next to the path.
	static func approve(
		path: String, keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) throws -> String {
		let url = try ExternalScriptRunner.validate(path: path)
		try ExternalScriptRunner.checkOwnershipAndPermissions(of: url.path)
		guard let key = try keyStore.key(createIfMissing: true) else {
			throw ExternalScriptError.notApproved
		}
		let fingerprint = try ScriptFingerprint.read(path: url.path)
		let code = HMAC<SHA256>.authenticationCode(for: Data(fingerprint.canonical.utf8), using: key)
		return Data(code).base64EncodedString()
	}

	static func isApproved(
		path: String, approval: String, keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Bool {
		guard let code = Data(base64Encoded: approval), code.count == SHA256.byteCount,
			let key = try? keyStore.key(createIfMissing: false),
			let resolved = try? ExternalScriptRunner.validate(path: path),
			let fingerprint = try? ScriptFingerprint.read(path: resolved.path)
		else { return false }
		return HMAC<SHA256>.isValidAuthenticationCode(
			code, authenticating: Data(fingerprint.canonical.utf8), using: key)
	}
}
