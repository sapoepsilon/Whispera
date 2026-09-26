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

/// Identity of a script file at the moment the user chose it: its resolved path, its owner and the
/// SHA-256 of its bytes. Any edit, replacement or move changes it and so invalidates the approval.
///
/// File metadata (inode, change and modification times, permission bits) is deliberately left
/// out. The runner executes a private copy of exactly the bytes that were hashed, so metadata adds
/// no protection, while it changes on harmless events (chmod, Finder tags, iCloud or Dropbox
/// extended attributes, a new hard link) and made approvals lapse for no reason. Permissions are
/// still checked on every run by `ExternalScriptRunner.checkOwnershipAndPermissions`.
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
		"v3|\(path)|\(owner)|\(contentDigest)"
	}

	/// The format approvals were signed with before v3. It covered strictly more than v3, so an
	/// approval that still verifies against it can be re-signed without asking the user again.
	var legacyV2Canonical: String {
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
		return sign(try ScriptFingerprint.read(path: url.path), with: key)
	}

	enum Verdict: Equatable, Sendable {
		case approved
		/// Signed in the older format and still valid; store `upgraded` in place of the old value.
		case approvedLegacy(upgraded: String)
		case refused

		var isApproved: Bool { self != .refused }

		var upgradedApproval: String? {
			if case .approvedLegacy(let upgraded) = self { return upgraded }
			return nil
		}
	}

	static func isApproved(
		path: String, approval: String, keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Bool {
		verdict(path: path, approval: approval, keyStore: keyStore).isApproved
	}

	static func verdict(
		path: String, approval: String, keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Verdict {
		guard let resolved = try? ExternalScriptRunner.validate(path: path),
			let snapshot = try? ScriptFingerprint.snapshot(path: resolved.path)
		else { return .refused }
		return verdict(snapshot: snapshot, approval: approval, keyStore: keyStore)
	}

	/// Checks the bytes that were read, so what runs afterwards is exactly what was verified.
	static func isApproved(
		snapshot: ScriptFingerprint.Snapshot, approval: String,
		keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Bool {
		verdict(snapshot: snapshot, approval: approval, keyStore: keyStore).isApproved
	}

	static func verdict(
		snapshot: ScriptFingerprint.Snapshot, approval: String,
		keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) -> Verdict {
		guard let code = Data(base64Encoded: approval), code.count == SHA256.byteCount,
			let key = try? keyStore.key(createIfMissing: false)
		else { return .refused }
		let fingerprint = snapshot.fingerprint
		if HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(fingerprint.canonical.utf8), using: key) {
			return .approved
		}
		if HMAC<SHA256>.isValidAuthenticationCode(
			code, authenticating: Data(fingerprint.legacyV2Canonical.utf8), using: key)
		{
			return .approvedLegacy(upgraded: sign(fingerprint, with: key))
		}
		return .refused
	}

	/// Re-signs an approval stored in an older format so it keeps working; one that no longer
	/// verifies is left alone and reported when the script is next used.
	static func upgradeStoredApproval(
		in defaults: UserDefaults, keyStore: ScriptApprovalKeyStore = KeychainScriptApprovalKeyStore()
	) {
		let settings = TextInsertionSettings(defaults: defaults)
		guard settings.pasteMethod == .externalScript, !settings.externalScriptPath.isEmpty,
			!settings.externalScriptApproval.isEmpty
		else { return }
		let verdict = verdict(
			path: settings.externalScriptPath, approval: settings.externalScriptApproval, keyStore: keyStore)
		if let upgraded = verdict.upgradedApproval {
			defaults.set(upgraded, forKey: TextInsertionSettings.Keys.externalScriptApproval)
			AppLogger.shared.general.info("Upgraded the insertion script approval to the current format")
		} else if verdict == .refused {
			AppLogger.shared.general.info("The insertion script approval no longer matches the script")
		}
	}

	private static func sign(_ fingerprint: ScriptFingerprint, with key: SymmetricKey) -> String {
		let code = HMAC<SHA256>.authenticationCode(for: Data(fingerprint.canonical.utf8), using: key)
		return Data(code).base64EncodedString()
	}
}
