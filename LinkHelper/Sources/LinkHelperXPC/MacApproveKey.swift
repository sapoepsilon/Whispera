import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The Mac's approve key (PROTOCOL §8.1): a Secure Enclave P-256 key that only signs after
/// `LAContext` confirms the owner — Touch ID, with the login password as the fallback. The
/// Keychain item (`MacApproveKeyStoring`) holds the enclave's wrapped handle, which no other Mac
/// and no other key can use.
public final class MacApproveKey: ApprovalAuthenticator, @unchecked Sendable {
	public struct Identity: Codable, Equatable, Sendable {
		public var deviceID: String
		public var keyBlob: Data
		public var publicKeyX963: Data
		public var createdAt: Int

		public init(deviceID: String, keyBlob: Data, publicKeyX963: Data, createdAt: Int) {
			self.deviceID = deviceID
			self.keyBlob = keyBlob
			self.publicKeyX963 = publicKeyX963
			self.createdAt = createdAt
		}

		enum CodingKeys: String, CodingKey {
			case deviceID = "device_id"
			case keyBlob = "key_blob"
			case publicKeyX963 = "public_key_x963"
			case createdAt = "created_at"
		}
	}

	/// Where earlier versions kept the identity as a plain file; moved into `store` on first read.
	public static var legacyFileURL: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera/link-approve-key.json")
	}

	public let store: MacApproveKeyStoring
	public let legacyFileURL: URL
	private let opensInEnclave: @Sendable (Identity) -> Bool
	private let log: @Sendable (String) -> Void
	private let lock = NSLock()
	private let storeLock = NSLock()
	private var context: LAContext?

	/// - Parameters:
	///   - opensInEnclave: whether a legacy file's key handle still opens as this Mac's enclave key
	///     with the recorded public key; checked before the file is imported and deleted.
	///   - log: one line per migration step or failure (the app passes its logger).
	public init(
		store: MacApproveKeyStoring = KeychainMacApproveKeyStore(),
		legacyFileURL: URL = MacApproveKey.legacyFileURL,
		opensInEnclave: @escaping @Sendable (Identity) -> Bool = MacApproveKey.opensInEnclave,
		log: @escaping @Sendable (String) -> Void = { _ in }
	) {
		self.store = store
		self.legacyFileURL = legacyFileURL
		self.opensInEnclave = opensInEnclave
		self.log = log
	}

	public var identity: Identity? {
		storeLock.lock()
		defer { storeLock.unlock() }
		let stored: Data?
		do {
			stored = try store.load()
		} catch {
			log("Approve key: cannot read the Keychain item (\(error))")
			return nil
		}
		if let stored, let identity = try? JSONDecoder().decode(Identity.self, from: stored) {
			removeLegacyFile(reason: "the Keychain already holds the key")
			return identity
		}
		return migrateLegacyFile()
	}

	/// The legacy file into the Keychain: imported only when its key still opens in the enclave,
	/// and deleted only once the Keychain gives the same bytes back. Any failure keeps the file,
	/// so the key is never lost.
	private func migrateLegacyFile() -> Identity? {
		guard let data = try? Data(contentsOf: legacyFileURL) else { return nil }
		guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
			log("Approve key: the legacy key file is unreadable; leaving it in place")
			return nil
		}
		guard opensInEnclave(identity) else {
			log("Approve key: the legacy key file does not open in this Mac's Secure Enclave; not migrating it")
			return identity
		}
		do {
			try store.save(data)
			guard try store.load() == data else {
				log("Approve key: the Keychain did not return the migrated key; keeping the legacy file")
				return identity
			}
		} catch {
			log("Approve key: cannot move the key into the Keychain (\(error)); keeping the legacy file")
			return identity
		}
		removeLegacyFile(reason: "migrated into the Keychain")
		return identity
	}

	private func removeLegacyFile(reason: String) {
		guard FileManager.default.fileExists(atPath: legacyFileURL.path) else { return }
		do {
			try FileManager.default.removeItem(at: legacyFileURL)
			log("Approve key: removed the legacy key file (\(reason))")
		} catch {
			log("Approve key: cannot remove the legacy key file: \(error.localizedDescription)")
		}
	}

	/// The handle opens as an enclave key (no prompt: only signing asks for the owner) and its
	/// public key is the one the file recorded.
	public static let opensInEnclave: @Sendable (Identity) -> Bool = { identity in
		guard SecureEnclave.isAvailable,
			let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: identity.keyBlob)
		else { return false }
		return key.publicKey.x963Representation == identity.publicKeyX963
	}

	public static var isAvailable: Bool { SecureEnclave.isAvailable }

	/// Creates a new key and device id, replacing any earlier one. No prompt: the key's access
	/// policy asks for the owner only when it signs.
	@discardableResult
	public func enroll(now: Int = Int(Date().timeIntervalSince1970)) throws -> Identity {
		guard SecureEnclave.isAvailable else { throw ApprovalAuthenticationError.failed("This Mac has no Secure Enclave.") }
		var error: Unmanaged<CFError>?
		guard
			let access = SecAccessControlCreateWithFlags(
				nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error)
		else {
			throw ApprovalAuthenticationError.failed("Couldn't create the key's access policy.")
		}
		let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
		let identity = Identity(
			deviceID: Self.newDeviceID(), keyBlob: key.dataRepresentation,
			publicKeyX963: key.publicKey.x963Representation, createdAt: now)
		let data = try JSONEncoder().encode(identity)
		storeLock.lock()
		defer { storeLock.unlock() }
		do {
			try store.save(data)
		} catch {
			throw ApprovalAuthenticationError.failed("Couldn't save the approval key in the Keychain: \(error)")
		}
		removeLegacyFile(reason: "replaced by a new key")
		return identity
	}

	public func remove() {
		storeLock.lock()
		defer { storeLock.unlock() }
		do {
			try store.delete()
		} catch {
			log("Approve key: cannot delete the Keychain item (\(error))")
		}
		removeLegacyFile(reason: "key removed")
	}

	/// What `enrollMacApprover` sends the helper.
	public static func enrollment(_ identity: Identity, name: String) -> Data {
		let object: [String: Any] = [
			"device_id": identity.deviceID, "name": name,
			"approve_pubkey": identity.publicKeyX963.base64EncodedString(),
		]
		return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
	}

	public func sign(_ message: Data, reason: String) async throws -> Data {
		guard let identity else { throw ApprovalAuthenticationError.noKey }
		let context = LAContext()
		context.touchIDAuthenticationAllowableReuseDuration = 0
		context.localizedFallbackTitle = "Use Password"
		track(context)
		defer { untrack(context) }
		var unavailable: NSError?
		let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable)
		do {
			do {
				try await context.evaluatePolicy(
					biometrics ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication,
					localizedReason: reason)
			} catch let error as LAError where biometrics && error.code == .userFallback {
				try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
			}
		} catch let error as LAError {
			switch error.code {
			case .userCancel, .appCancel, .systemCancel: throw ApprovalAuthenticationError.cancelled
			default: throw ApprovalAuthenticationError.failed(error.localizedDescription)
			}
		}
		do {
			let key = try SecureEnclave.P256.Signing.PrivateKey(
				dataRepresentation: identity.keyBlob, authenticationContext: context)
			return try key.signature(for: message).derRepresentation
		} catch {
			throw ApprovalAuthenticationError.failed("The approval key couldn't sign: \(error.localizedDescription)")
		}
	}

	private func track(_ context: LAContext) {
		lock.lock()
		self.context = context
		lock.unlock()
	}

	private func untrack(_ context: LAContext) {
		lock.lock()
		if self.context === context { self.context = nil }
		lock.unlock()
	}

	public func cancel() {
		lock.lock()
		let context = self.context
		lock.unlock()
		context?.invalidate()
	}

	/// `dev_` + 24 base32 characters (`[a-z2-7]`), the shape §2.1 gives every device id.
	static func newDeviceID() -> String {
		var bytes = [UInt8](repeating: 0, count: 15)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return "dev_" + base32(bytes)
	}

	static func base32(_ bytes: [UInt8]) -> String {
		let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
		var out = ""
		var buffer = 0
		var bits = 0
		for byte in bytes {
			buffer = (buffer << 8) | Int(byte)
			bits += 8
			while bits >= 5 {
				out.append(alphabet[(buffer >> (bits - 5)) & 31])
				bits -= 5
			}
		}
		if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
		return out
	}
}
