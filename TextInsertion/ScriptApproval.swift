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
/// changes it, and so invalidates the approval. The change time cannot be set by user code, and
/// the content digest catches a same-size rewrite even if the change time were restored.
struct ScriptFingerprint: Equatable, Sendable {
	/// Larger files are refused rather than hashed on every dictation.
	static let maximumSize = 32 * 1024 * 1024

	let path: String
	let device: Int64
	let inode: UInt64
	let size: Int64
	let modifiedSeconds: Int
	let modifiedNanoseconds: Int
	let changedSeconds: Int
	let changedNanoseconds: Int
	let owner: UInt32
	let mode: UInt16
	let contentDigest: String

	/// The fingerprint plus the exact bytes it was computed from, so the caller can run those
	/// bytes instead of reopening a path that may have changed since.
	struct Snapshot: Sendable {
		let fingerprint: ScriptFingerprint
		let contents: Data
	}

	static func read(path: String) throws -> ScriptFingerprint {
		try snapshot(path: path).fingerprint
	}

	static func snapshot(path: String) throws -> Snapshot {
		let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { throw ExternalScriptError.notExecutable(path) }
		defer { close(fd) }
		var before = stat()
		guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
			throw ExternalScriptError.notExecutable(path)
		}
		guard before.st_size <= maximumSize else {
			throw ExternalScriptError.unsafePermissions("it is larger than 32 MB")
		}
		let contents = try readAll(fd: fd, path: path)
		var after = stat()
		guard fstat(fd, &after) == 0, sameVersion(before, after), Int64(contents.count) == Int64(after.st_size)
		else { throw ExternalScriptError.notApproved }
		let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
		let fingerprint = ScriptFingerprint(
			path: path,
			device: Int64(after.st_dev),
			inode: UInt64(after.st_ino),
			size: Int64(after.st_size),
			modifiedSeconds: after.st_mtimespec.tv_sec,
			modifiedNanoseconds: after.st_mtimespec.tv_nsec,
			changedSeconds: after.st_ctimespec.tv_sec,
			changedNanoseconds: after.st_ctimespec.tv_nsec,
			owner: after.st_uid,
			mode: UInt16(after.st_mode),
			contentDigest: digest
		)
		return Snapshot(fingerprint: fingerprint, contents: contents)
	}

	private static func readAll(fd: Int32, path: String) throws -> Data {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		while true {
			let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
			if count < 0 {
				if errno == EINTR { continue }
				throw ExternalScriptError.notExecutable(path)
			}
			if count == 0 { return data }
			data.append(contentsOf: buffer[0..<count])
			guard data.count <= maximumSize else {
				throw ExternalScriptError.unsafePermissions("it is larger than 32 MB")
			}
		}
	}

	private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
		lhs.st_size == rhs.st_size
			&& lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
			&& lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
			&& lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
			&& lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
	}

	var canonical: String {
		"v2|\(path)|\(device)|\(inode)|\(size)|\(modifiedSeconds).\(modifiedNanoseconds)"
			+ "|\(changedSeconds).\(changedNanoseconds)|\(owner)|\(mode)|\(contentDigest)"
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
		guard let resolved = try? ExternalScriptRunner.validate(path: path),
			let snapshot = try? ScriptFingerprint.snapshot(path: resolved.path)
		else { return false }
		return isApproved(snapshot: snapshot, approval: approval, keyStore: keyStore)
	}

	/// Checks the bytes that were read, so what runs afterwards is exactly what was verified.
	static func isApproved(
		snapshot: ScriptFingerprint.Snapshot, approval: String,
		keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Bool {
		guard let code = Data(base64Encoded: approval), code.count == SHA256.byteCount,
			let key = try? keyStore.key(createIfMissing: false)
		else { return false }
		return HMAC<SHA256>.isValidAuthenticationCode(
			code, authenticating: Data(snapshot.fingerprint.canonical.utf8), using: key)
	}
}
