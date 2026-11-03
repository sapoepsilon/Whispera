import Foundation

// Account pairing: devices signed into the same account find each other through the
// backend's device list instead of a pairing code. The list is self-consistent only:
// every key is checked against its fingerprint and the KEM record against the link
// key, but the backend supplies both halves, so "trusted" here means "well formed".
// Trust in a device comes from the owner comparing its `SafetyNumber` on both screens;
// after that its keys are pinned (`PinnedDeviceKeys`) and any change is
// `untrusted(.keyChanged)` until the owner confirms it again.

/// Builds and sends the `POST /v1/devices` that puts this device on the account.
public enum AccountDeviceRegistration {
	/// The backend's `name` limit; longer names are cut.
	public static let maxNameLength = 64

	/// `link_pubkey` + optional `approve_pubkey` + `kem_pubkey` = the agreement key in
	/// a `KEMKeyRecord` signed by `linkKey`.
	public static func request(
		name: String, platform: Platform = .current, linkKey: LinkSigningKey, approveKey: LinkPublicKey? = nil,
		agreementKey: LinkPublicKey, apns: ApnsRegistration? = nil
	) throws -> RegisterDeviceRequest {
		RegisterDeviceRequest(
			name: String(name.prefix(maxNameLength)), platform: platform, link_pubkey: linkKey.publicKey.x963Base64,
			approve_pubkey: approveKey?.x963Base64,
			kem_pubkey: try KEMKeyRecord.sign(agreementKey, linkKey: linkKey).base64, apns: apns)
	}

	/// Registers and checks the record the backend returns carries exactly the keys
	/// sent. Store the returned `device_id`: every WL1 call signs as it.
	public static func register(
		baseURL: URL, accountToken: String, name: String, platform: Platform = .current, linkKey: LinkSigningKey,
		approveKey: LinkPublicKey? = nil, agreementKey: LinkPublicKey, apns: ApnsRegistration? = nil,
		transport: LinkTransport = URLSessionLinkTransport()
	) async throws -> PublicDevice {
		let body = try request(
			name: name, platform: platform, linkKey: linkKey, approveKey: approveKey, agreementKey: agreementKey, apns: apns)
		let device = try await RelayClient.register(baseURL: baseURL, accountToken: accountToken, body, transport: transport)
		guard try device.verifiedLinkKey() == linkKey.publicKey,
		      try device.verifiedAgreementKey() == agreementKey,
		      device.approve_pubkey == body.approve_pubkey
		else { throw RelayError.fingerprintMismatch(device.device_id) }
		return device
	}
}

/// A device of the account whose keys all verified.
public struct TrustedDevice: Equatable, Sendable, Identifiable {
	public let device: PublicDevice
	/// Fingerprint-checked.
	public let linkKey: LinkPublicKey
	/// From the KEM record, signature-checked against `linkKey`.
	public let agreementKey: LinkPublicKey
	/// Fingerprint-checked; nil when the device registered none.
	public let approveKey: LinkPublicKey?

	public var id: String { device.device_id }
	public var name: String { device.name }
	public var platform: Platform { device.platform }
	/// `xxxx-xxxx-xxxx-xxxx` of the link key — what a confirm card shows.
	public var displayFingerprint: String { linkKey.displayFingerprint }

	/// Verifies everything or throws why not.
	public init(verifying device: PublicDevice) throws {
		let link = try device.verifiedLinkKey()
		guard let agreement = try device.verifiedAgreementKey() else { throw RelayError.noAgreementKey(device.device_id) }
		var approve: LinkPublicKey?
		if let raw = device.approve_pubkey {
			let key = try LinkPublicKey(x963Base64: raw)
			guard key.fingerprint == device.approve_fp?.lowercased() else { throw RelayError.fingerprintMismatch(device.device_id) }
			approve = key
		} else if device.approve_fp != nil {
			throw RelayError.fingerprintMismatch(device.device_id)
		}
		self.device = device
		linkKey = link
		agreementKey = agreement
		approveKey = approve
	}
}

/// The keys a device had when the owner confirmed it (trust on first confirm). A device
/// whose listed keys differ is classified `untrusted(.keyChanged)`.
public struct PinnedDeviceKeys: Codable, Equatable, Sendable {
	public let deviceID: String
	public let linkPubkey: String
	public let approvePubkey: String?
	public let agreementPubkey: String

	public init(deviceID: String, linkPubkey: String, approvePubkey: String?, agreementPubkey: String) {
		self.deviceID = deviceID
		self.linkPubkey = linkPubkey
		self.approvePubkey = approvePubkey
		self.agreementPubkey = agreementPubkey
	}

	public init(_ device: TrustedDevice) {
		self.init(
			deviceID: device.id, linkPubkey: device.linkKey.x963Base64, approvePubkey: device.approveKey?.x963Base64,
			agreementPubkey: device.agreementKey.x963Base64)
	}

	public func matches(_ device: TrustedDevice) -> Bool {
		self == PinnedDeviceKeys(device)
	}
}

/// A device the backend listed whose keys did not verify. Shown, if at all, as a
/// warning — never paired with, sealed to, or accepted from.
public struct UntrustedDevice: Equatable, Sendable, Identifiable {
	public enum Reason: Equatable, Sendable {
		/// `link_pubkey` is malformed or does not hash to `link_fp`, or the approve key
		/// does not hash to `approve_fp`.
		case fingerprintMismatch
		/// `kem_pubkey` is not a `KEMKeyRecord` signed by the device's link key.
		case badKEMRecord
		/// No `kem_pubkey`: nothing can be sealed to it.
		case noAgreementKey
		/// Its keys verify but differ from the ones pinned when the owner confirmed it: a new
		/// phone, a reinstall, or a backend substituting keys. Never used until re-confirmed.
		case keyChanged
	}

	public let device: PublicDevice
	public let reason: Reason
	public var id: String { device.device_id }
}

/// The account's devices as this device should see them (`GET /v1/devices` with the
/// bearer, or WL1 `GET /v1/device/peers` — both list only the caller's account).
///
/// Revoked devices are dropped (their ids are kept in `revokedIDs` so a host can
/// unpair from them); every other device is verified and lands in exactly one of
/// `me`, `macs`, `phones`, `others` or `untrusted`.
public struct AccountDevices: Equatable, Sendable {
	/// This device, when `selfID` was given and it verified.
	public let me: TrustedDevice?
	public let macs: [TrustedDevice]
	public let phones: [TrustedDevice]
	/// Linux and other platforms.
	public let others: [TrustedDevice]
	public let untrusted: [UntrustedDevice]
	public let revokedIDs: Set<String>

	/// `pinned`: keys confirmed earlier, by device id. A listed device whose keys differ from
	/// its pin lands in `untrusted` with `.keyChanged`.
	public init(classifying devices: [PublicDevice], selfID: String?, pinned: [String: PinnedDeviceKeys] = [:]) {
		var me: TrustedDevice?
		var macs: [TrustedDevice] = [], phones: [TrustedDevice] = [], others: [TrustedDevice] = []
		var untrusted: [UntrustedDevice] = []
		var revoked: Set<String> = []
		var seen: Set<String> = []
		for device in devices {
			guard seen.insert(device.device_id).inserted else { continue }
			if device.isRevoked {
				revoked.insert(device.device_id)
				continue
			}
			let trusted: TrustedDevice
			do {
				trusted = try TrustedDevice(verifying: device)
			} catch {
				untrusted.append(UntrustedDevice(device: device, reason: Self.reason(for: error)))
				continue
			}
			if device.device_id == selfID {
				me = trusted
				continue
			}
			if let pin = pinned[device.device_id], !pin.matches(trusted) {
				untrusted.append(UntrustedDevice(device: device, reason: .keyChanged))
				continue
			}
			switch device.platform {
			case .macos: macs.append(trusted)
			case .ios: phones.append(trusted)
			case .linux, .other: others.append(trusted)
			}
		}
		self.me = me
		self.macs = macs
		self.phones = phones
		self.others = others
		self.untrusted = untrusted
		revokedIDs = revoked
	}

	/// Every verified device other than this one — who to seal to and accept from.
	public var peers: [TrustedDevice] { macs + phones + others }

	/// A verified peer by id; nil for this device, an untrusted, revoked or unknown one.
	public func peer(_ deviceID: String) -> TrustedDevice? {
		peers.first { $0.device.device_id == deviceID }
	}

	private static func reason(for error: Error) -> UntrustedDevice.Reason {
		switch error {
		case RelayError.badKEMRecord: return .badKEMRecord
		case RelayError.noAgreementKey: return .noAgreementKey
		default: return .fingerprintMismatch
		}
	}
}
