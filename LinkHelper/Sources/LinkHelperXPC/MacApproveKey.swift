import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The Mac's approve key (PROTOCOL §8.1): a Secure Enclave P-256 key that only signs after
/// `LAContext` confirms the owner — Touch ID, with the login password as the fallback. The file
/// holds the enclave's wrapped handle, which no other Mac and no other key can use.
public final class MacApproveKey: ApprovalAuthenticator, @unchecked Sendable {
	public struct Identity: Codable, Equatable, Sendable {
		public var deviceID: String
		public var keyBlob: Data
		public var publicKeyX963: Data
		public var createdAt: Int

		enum CodingKeys: String, CodingKey {
			case deviceID = "device_id"
			case keyBlob = "key_blob"
			case publicKeyX963 = "public_key_x963"
			case createdAt = "created_at"
		}
	}

	public static var defaultURL: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera/link-approve-key.json")
	}

	public let fileURL: URL
	private let lock = NSLock()
	private var context: LAContext?

	public init(fileURL: URL = MacApproveKey.defaultURL) {
		self.fileURL = fileURL
	}

	public var identity: Identity? {
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		return try? JSONDecoder().decode(Identity.self, from: data)
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
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try JSONEncoder().encode(identity)
		try data.write(to: fileURL, options: [.atomic])
		chmod(fileURL.path, 0o600)
		return identity
	}

	public func remove() {
		try? FileManager.default.removeItem(at: fileURL)
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
