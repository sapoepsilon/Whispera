import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: Key abstractions

/// A P-256 ECDSA key that signs protocol messages: the link key (every request, no
/// prompt), the approve key (approvals, behind biometry), or a daemon key.
///
/// The protocol is what makes the Secure Enclave swappable: production code holds an
/// `EnclaveSigningKey`, tests and the simulator hold a `SoftwareSigningKey`, and
/// everything that signs only sees this.
public protocol LinkSigningKey: Sendable {
	var publicKeyX963: Data { get }
	/// ECDSA P-256 / SHA-256 over `message`, ASN.1 DER.
	func sign(_ message: Data) throws -> Data
}

extension LinkSigningKey {
	public var publicKey: LinkPublicKey {
		// Every conforming key is a real P-256 key, so this cannot fail.
		// swiftlint:disable:next force_try
		try! LinkPublicKey(x963: publicKeyX963)
	}
}

/// An in-memory key. For tests, the simulator, and the vectors (which ship PKCS#8 PEM).
public struct SoftwareSigningKey: LinkSigningKey {
	public let privateKey: P256.Signing.PrivateKey

	public init(_ privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
		self.privateKey = privateKey
	}

	/// A PKCS#8 `PRIVATE KEY` PEM (`SigningKey::from_pkcs8_pem`).
	public init(pkcs8PEM: String) throws {
		do {
			privateKey = try P256.Signing.PrivateKey(pemRepresentation: pkcs8PEM)
		} catch {
			throw LinkKeyError.privateKey
		}
	}

	public var publicKeyX963: Data { privateKey.publicKey.x963Representation }

	public func sign(_ message: Data) throws -> Data {
		try privateKey.signature(for: message).derRepresentation
	}
}

/// A Secure Enclave key. The private half never leaves the enclave; what the Keychain
/// stores is an opaque, device-bound handle.
public struct EnclaveSigningKey: LinkSigningKey, @unchecked Sendable {
	public let privateKey: SecureEnclave.P256.Signing.PrivateKey

	public init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
		self.privateKey = privateKey
	}

	public var publicKeyX963: Data { privateKey.publicKey.x963Representation }

	public func sign(_ message: Data) throws -> Data {
		try privateKey.signature(for: message).derRepresentation
	}
}

/// A P-256 key-agreement key: the recipient key a relay envelope is sealed to.
///
/// Kept apart from the signing keys on purpose — one key, one job. A device publishes
/// it next to its link and approve keys; see `SealedEnvelope` for how it is used.
public protocol LinkAgreementKey: Sendable {
	var publicKeyX963: Data { get }
	/// An HPKE receiving context for one envelope.
	func hpkeRecipient(ciphersuite: HPKE.Ciphersuite, info: Data, encapsulatedKey: Data) throws -> HPKE.Recipient
	/// Static ECDH with a peer's agreement key — the WLP1 push key (`PushSealing`).
	func sharedSecret(with peer: LinkPublicKey) throws -> SharedSecret
}

extension LinkAgreementKey {
	public var publicKey: LinkPublicKey {
		// swiftlint:disable:next force_try
		try! LinkPublicKey(x963: publicKeyX963)
	}
}

public struct SoftwareAgreementKey: LinkAgreementKey {
	public let privateKey: P256.KeyAgreement.PrivateKey

	public init(_ privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
		self.privateKey = privateKey
	}

	public var publicKeyX963: Data { privateKey.publicKey.x963Representation }

	public func hpkeRecipient(ciphersuite: HPKE.Ciphersuite, info: Data, encapsulatedKey: Data) throws -> HPKE.Recipient {
		try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite, info: info, encapsulatedKey: encapsulatedKey)
	}

	public func sharedSecret(with peer: LinkPublicKey) throws -> SharedSecret {
		try privateKey.sharedSecretFromKeyAgreement(with: peer.agreementKey)
	}
}

public struct EnclaveAgreementKey: LinkAgreementKey, @unchecked Sendable {
	public let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

	public init(privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey) {
		self.privateKey = privateKey
	}

	public var publicKeyX963: Data { privateKey.publicKey.x963Representation }

	public func hpkeRecipient(ciphersuite: HPKE.Ciphersuite, info: Data, encapsulatedKey: Data) throws -> HPKE.Recipient {
		try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite, info: info, encapsulatedKey: encapsulatedKey)
	}

	public func sharedSecret(with peer: LinkPublicKey) throws -> SharedSecret {
		try privateKey.sharedSecretFromKeyAgreement(with: peer.agreementKey)
	}
}

// MARK: Errors

public enum DeviceKeyError: LocalizedError {
	case secureEnclaveUnavailable
	case accessControl
	case keychain(OSStatus)
	case missingKey(String)
	case authenticationFailed(String)

	public var errorDescription: String? {
		switch self {
		case .secureEnclaveUnavailable:
			return "This device has no Secure Enclave, so it cannot hold Whispera link keys."
		case .accessControl:
			return "Could not create the key access policy."
		case .keychain(let status):
			return "Keychain error \(status)."
		case .missingKey(let name):
			return "The \(name) key is missing. Pair this device again."
		case .authenticationFailed(let reason):
			return reason
		}
	}
}

// MARK: Approve key policy

/// What unlocks the approve key. Fixed when the key is made: changing it means a new key,
/// which every Mac that confirmed the old one has to confirm again.
public enum ApproveKeyPolicy: String, Sendable, Codable, CaseIterable {
	/// Face ID / Touch ID, or the device passcode (`.userPresence`). The default.
	case userPresence
	/// Only the biometrics enrolled when the key was made (`.biometryCurrentSet`): no
	/// passcode fallback, and enrolling another face or finger voids the key.
	case biometryCurrentSet

	/// The Secure Enclave access-control flags for an approve key under this policy.
	public var accessControlFlags: SecAccessControlCreateFlags {
		switch self {
		case .userPresence: return [.privateKeyUsage, .userPresence]
		case .biometryCurrentSet: return [.privateKeyUsage, .biometryCurrentSet]
		}
	}

	/// The LocalAuthentication policy that stands in for the key's own check where there is
	/// no Secure Enclave (software keys).
	public var ownerPolicy: LAPolicy {
		switch self {
		case .userPresence: return .deviceOwnerAuthentication
		case .biometryCurrentSet: return .deviceOwnerAuthenticationWithBiometrics
		}
	}
}

// MARK: Device key store

/// A device's keys (protocol §2): a link key that signs every request with no prompt,
/// an approve key gated by its `ApproveKeyPolicy` (by default `.userPresence`: Face ID,
/// Touch ID or passcode), and an agreement key that relay envelopes are sealed to.
///
/// The approve key's policy is recorded next to it, so signing evaluates the same access
/// control the key was made with. A key made before policies were recorded is
/// `.userPresence`, which is what every key was then.
///
/// Key blobs live in the Keychain as `kSecClassGenericPassword`, this-device-only,
/// under `service` — each host picks its own, so the iPhone app, the Mac app and its
/// helper never read each other's keys. With `usesSoftwareKeys` the keys are plain
/// CryptoKit keys instead of Secure Enclave handles: the simulator has no enclave.
public struct DeviceKeys: Sendable {
	public enum Kind: String, Sendable, CaseIterable {
		case link
		case approve
		/// The HPKE recipient key for relay envelopes.
		case agreement
	}

	public let service: String
	public let usesSoftwareKeys: Bool
	public let keychain: KeychainStore
	/// With software keys only: what stands in for the approve key's owner check. Nil asks
	/// LocalAuthentication (`ApproveKeyPolicy.ownerPolicy`); tests and recording rigs
	/// inject an answer. Ignored for Secure Enclave keys, whose check the enclave enforces.
	public var softwareOwnerCheck: (@Sendable (ApproveKeyPolicy, String) async throws -> Void)?

	/// Keychain accounts beside the keys: the approve key's policy, and a replacement
	/// approve key while `replaceApproveKey` waits for its commit.
	static let approvePolicyAccount = "approve.policy"
	static let stagedApproveAccount = "approve.staged"

	/// Software keys by default only in a DEBUG simulator build, as the app did.
	public static var defaultUsesSoftwareKeys: Bool {
		#if DEBUG && targetEnvironment(simulator)
			return true
		#else
			return false
		#endif
	}

	/// - Parameter useDataProtectionKeychain: macOS only. `true` stores items in the
	///   iOS-style data protection keychain, which needs a signed app with a
	///   keychain access group; leave it `false` for an unsigned helper or tests.
	public init(service: String, usesSoftwareKeys: Bool = DeviceKeys.defaultUsesSoftwareKeys, useDataProtectionKeychain: Bool = false) {
		self.service = service
		self.usesSoftwareKeys = usesSoftwareKeys
		keychain = KeychainStore(service: service, useDataProtectionKeychain: useDataProtectionKeychain)
	}

	// MARK: Signing keys

	/// Makes (replacing) the `kind` key. `approvePolicy` applies to the approve key only.
	public func create(
		_ kind: Kind, approveContext: LAContext? = nil, approvePolicy: ApproveKeyPolicy = .userPresence
	) throws -> LinkSigningKey {
		precondition(kind != .agreement, "use createAgreementKey()")
		try? delete(kind)
		let (key, blob) = try makeSigningKey(kind, approveContext: approveContext, approvePolicy: approvePolicy)
		try keychain.set(blob, account: kind.rawValue)
		if kind == .approve { try setStoredApprovePolicy(approvePolicy) }
		return key
	}

	/// A new key and the blob that stores it, not saved anywhere yet.
	private func makeSigningKey(
		_ kind: Kind, approveContext: LAContext?, approvePolicy: ApproveKeyPolicy
	) throws -> (LinkSigningKey, Data) {
		if usesSoftwareKeys {
			let key = P256.Signing.PrivateKey()
			return (SoftwareSigningKey(key), key.rawRepresentation)
		}
		guard SecureEnclave.isAvailable else { throw DeviceKeyError.secureEnclaveUnavailable }
		let access = try Self.accessControl(for: kind, approvePolicy: approvePolicy)
		let key = try SecureEnclave.P256.Signing.PrivateKey(
			compactRepresentable: false,
			accessControl: access,
			authenticationContext: kind == .approve ? approveContext : nil)
		return (EnclaveSigningKey(privateKey: key), key.dataRepresentation)
	}

	public func load(_ kind: Kind, context: LAContext? = nil) throws -> LinkSigningKey {
		precondition(kind != .agreement, "use loadAgreementKey()")
		guard let blob = try keychain.get(account: kind.rawValue) else {
			throw DeviceKeyError.missingKey(kind.rawValue)
		}
		if usesSoftwareKeys {
			return SoftwareSigningKey(try P256.Signing.PrivateKey(rawRepresentation: blob))
		}
		let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
		return EnclaveSigningKey(privateKey: key)
	}

	// MARK: Agreement key

	/// The agreement key needs no prompt: opening an envelope is not an approval. What
	/// an envelope asks for still goes through the approve key.
	public func createAgreementKey() throws -> LinkAgreementKey {
		try? delete(.agreement)
		if usesSoftwareKeys {
			let key = P256.KeyAgreement.PrivateKey()
			try keychain.set(key.rawRepresentation, account: Kind.agreement.rawValue)
			return SoftwareAgreementKey(key)
		}
		guard SecureEnclave.isAvailable else { throw DeviceKeyError.secureEnclaveUnavailable }
		let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
			compactRepresentable: false, accessControl: try Self.accessControl(for: .agreement))
		try keychain.set(key.dataRepresentation, account: Kind.agreement.rawValue)
		return EnclaveAgreementKey(privateKey: key)
	}

	public func loadAgreementKey() throws -> LinkAgreementKey {
		guard let blob = try keychain.get(account: Kind.agreement.rawValue) else {
			throw DeviceKeyError.missingKey(Kind.agreement.rawValue)
		}
		if usesSoftwareKeys {
			return SoftwareAgreementKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: blob))
		}
		return EnclaveAgreementKey(privateKey: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob))
	}

	// MARK: Housekeeping

	public func delete(_ kind: Kind) throws {
		try keychain.delete(account: kind.rawValue)
		if kind == .approve {
			try? keychain.delete(account: Self.approvePolicyAccount)
			try? keychain.delete(account: Self.stagedApproveAccount)
		}
	}

	public func deleteAll() {
		for kind in Kind.allCases { try? delete(kind) }
	}

	// MARK: Approve key policy

	/// The policy the stored approve key was made with; `.userPresence` when none is
	/// recorded (a key from before policies were recorded, or no key).
	public func approvePolicy() -> ApproveKeyPolicy {
		guard let raw = try? keychain.get(account: Self.approvePolicyAccount),
			let policy = ApproveKeyPolicy(rawValue: String(decoding: raw, as: UTF8.self))
		else { return .userPresence }
		return policy
	}

	private func setStoredApprovePolicy(_ policy: ApproveKeyPolicy) throws {
		try keychain.set(Data(policy.rawValue.utf8), account: Self.approvePolicyAccount)
	}

	/// Replaces the approve key with one made under `policy`, all or nothing:
	///
	/// 1. The owner proves they can use the current approve key: it signs a fresh random
	///    challenge under its own access control (Face ID, or Face ID or passcode), and the
	///    signature is checked against its public key. Cancel or failure throws
	///    `authenticationFailed` and nothing changes.
	/// 2. The new key is made and held aside (`approve.staged`), not yet the approve key.
	/// 3. `commit` gets its public key (the host registers it with its peers). If `commit`
	///    throws, the new key is deleted and the current one stays.
	/// 4. Only then does the new key (and its policy) replace the current one.
	///
	/// Every peer that confirmed the old approve key must confirm the new one.
	@discardableResult
	public func replaceApproveKey(
		policy: ApproveKeyPolicy, reason: String, commit: (LinkPublicKey) async throws -> Void
	) async throws -> LinkSigningKey {
		let current = try load(.approve).publicKey
		let challenge = LinkCrypto.randomBytes(32)
		let signature = try await signWithApproveKey(challenge, reason: reason)
		guard current.isValidSignature(signature, for: challenge) else {
			throw DeviceKeyError.authenticationFailed("The approval key did not verify.")
		}
		let (key, blob) = try makeSigningKey(.approve, approveContext: nil, approvePolicy: policy)
		try keychain.set(blob, account: Self.stagedApproveAccount)
		do {
			try await commit(key.publicKey)
		} catch {
			try? keychain.delete(account: Self.stagedApproveAccount)
			throw error
		}
		try keychain.set(blob, account: Kind.approve.rawValue)
		try setStoredApprovePolicy(policy)
		try? keychain.delete(account: Self.stagedApproveAccount)
		return key
	}

	// MARK: Approvals

	/// Signs with the approve key after a fresh check under the key's own policy. A
	/// cancelled or failed Face ID / Touch ID (or passcode, where the policy allows it)
	/// throws, so nothing is ever sent without it.
	public func signWithApproveKey(_ message: Data, reason: String) async throws -> Data {
		let policy = approvePolicy()
		let context = LAContext()
		context.touchIDAuthenticationAllowableReuseDuration = 0
		context.localizedReason = reason
		if usesSoftwareKeys {
			try await checkOwner(context, policy: policy, reason: reason)
			return try load(.approve).sign(message)
		}
		let access = try Self.accessControl(for: .approve, approvePolicy: policy)
		do {
			try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason)
		} catch {
			throw DeviceKeyError.authenticationFailed(error.localizedDescription)
		}
		return try load(.approve, context: context).sign(message)
	}

	/// Makes the approve key and signs `message` with it under one biometric prompt —
	/// the pairing approve-proof.
	public func createApproveKeyAndProve(
		_ message: Data, reason: String, policy: ApproveKeyPolicy = .userPresence
	) async throws -> (LinkSigningKey, Data) {
		let context = LAContext()
		context.touchIDAuthenticationAllowableReuseDuration = 0
		context.localizedReason = reason
		if usesSoftwareKeys {
			try await checkOwner(context, policy: policy, reason: reason)
			let key = try create(.approve, approvePolicy: policy)
			return (key, try key.sign(message))
		}
		let access = try Self.accessControl(for: .approve, approvePolicy: policy)
		do {
			try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason)
		} catch {
			throw DeviceKeyError.authenticationFailed(error.localizedDescription)
		}
		let key = try create(.approve, approveContext: context, approvePolicy: policy)
		return (key, try key.sign(message))
	}

	/// Software keys: the injected check, or LocalAuthentication under `policy`.
	private func checkOwner(_ context: LAContext, policy: ApproveKeyPolicy, reason: String) async throws {
		do {
			if let softwareOwnerCheck {
				try await softwareOwnerCheck(policy, reason)
			} else {
				try await context.evaluatePolicy(policy.ownerPolicy, localizedReason: reason)
			}
		} catch let error as DeviceKeyError {
			throw error
		} catch {
			throw DeviceKeyError.authenticationFailed(error.localizedDescription)
		}
	}

	static func accessControl(for kind: Kind, approvePolicy: ApproveKeyPolicy = .userPresence) throws -> SecAccessControl {
		let protection: CFString
		let flags: SecAccessControlCreateFlags
		switch kind {
		case .link, .agreement:
			protection = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			flags = [.privateKeyUsage]
		case .approve:
			protection = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
			flags = approvePolicy.accessControlFlags
		}
		guard let access = SecAccessControlCreateWithFlags(nil, protection, flags, nil) else {
			throw DeviceKeyError.accessControl
		}
		return access
	}
}

// MARK: Keychain

/// Generic-password items under one service, this-device-only.
public struct KeychainStore: Sendable {
	public let service: String
	public let useDataProtectionKeychain: Bool

	public init(service: String, useDataProtectionKeychain: Bool = false) {
		self.service = service
		self.useDataProtectionKeychain = useDataProtectionKeychain
	}

	private func baseQuery(account: String) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		#if os(macOS)
			if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
		#endif
		return query
	}

	public func set(_ data: Data, account: String) throws {
		let query = baseQuery(account: account)
		SecItemDelete(query as CFDictionary)
		var attributes = query
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(attributes as CFDictionary, nil)
		guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
	}

	public func get(account: String) throws -> Data? {
		var query = baseQuery(account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
		return result as? Data
	}

	public func delete(account: String) throws {
		let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw DeviceKeyError.keychain(status)
		}
	}
}
