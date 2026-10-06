// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import AuthenticationServices
import Foundation
import LinkHelperXPC
import LocalAuthentication
import WhisperaAccount
import WhisperaLink

// Account pairing on the Mac: sign in to a Whispera account (hosted, a self-hosted OpenID
// provider, or a server token), hand the bearer to the link helper so it joins the account, list
// and revoke the account's devices, and confirm a new iPhone's approve rights with Touch ID.

/// How the Mac signs in.
enum AccountProvider: String, CaseIterable, Identifiable {
	/// The hosted Whispera account (Clerk).
	case hosted
	/// A self-hosted OpenID Connect issuer (Keycloak, Authentik, the dev IdP, …).
	case custom
	/// A long-lived token the self-hosted server accepts.
	case serverToken

	var id: String { rawValue }

	var title: String {
		switch self {
		case .hosted: return String(localized: "Whispera account")
		case .custom: return String(localized: "Custom issuer")
		case .serverToken: return String(localized: "Server token")
		}
	}
}

/// Where the account settings live. The hosted Clerk client id is owner-provided: it comes from
/// the `WHISPERA_CLERK_CLIENT_ID` build setting (Info.plist `WhisperaClerkClientID`) and can be
/// overridden with the `whisperaAccountClerkClientID` default; this repository ships none.
enum AccountSettingsKeys {
	static let backendURL = "whisperaAccountBackendURL"
	static let provider = "whisperaAccountProvider"
	static let customIssuer = "whisperaAccountCustomIssuer"
	static let customClientID = "whisperaAccountCustomClientID"
	static let clerkClientID = "whisperaAccountClerkClientID"
	static let defaultBackendURL = "https://api.mansurov.dev"
	static let infoPlistClerkClientID = "WhisperaClerkClientID"
	static let keychainService = "com.macwhisper.app.account"

	static func hostedClientID(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> String {
		if let override = defaults.string(forKey: clerkClientID)?.trimmingCharacters(in: .whitespaces),
			!override.isEmpty
		{
			return override
		}
		let value = (bundle.object(forInfoDictionaryKey: infoPlistClerkClientID) as? String ?? "")
			.trimmingCharacters(in: .whitespaces)
		return value.hasPrefix("$(") ? "" : value
	}
}

// MARK: - Seams

/// Signing in and the stored credential (`AccountSignIn` in the app, a fake in tests).
protocol AccountSigningIn: Sendable {
	func signIn(configuration: OIDCConfiguration) async throws -> AccountCredential
	func useServerToken(_ token: String) async throws -> AccountCredential
	/// A bearer for the backend, refreshed when needed.
	func validBearer() async throws -> String
	func credential() async -> AccountCredential?
	func signOut() async throws
}

/// The account's device registry (`RelayClient` with the account bearer).
protocol AccountDirectory: Sendable {
	func devices(baseURL: URL, bearer: String) async throws -> [PublicDevice]
	func revoke(baseURL: URL, bearer: String, deviceID: String) async throws
}

/// The link helper's account calls (XPC).
protocol HelperAccountLinking: Sendable {
	func setAccount(bearer: String, backendURL: URL) async -> HelperAccountStatus?
	func clearAccount() async -> HelperAccountStatus?
	func accountStatus() async -> HelperAccountStatus?
	func pendingConfirmations() async -> [PendingApproveConfirmation]?
	func confirmApprove(deviceID: String) async -> Bool
}

enum AuthenticatorResult: Equatable, Sendable {
	case success
	case cancelled
	case failed(String)
}

/// The owner proves presence before a phone may approve secrets (Touch ID; a password where a
/// Mac has no Touch ID).
protocol Authenticator: Sendable {
	func authenticate(reason: String) async -> AuthenticatorResult
}

// MARK: - Live implementations

/// `LAContext` owner authentication.
struct LocalAuthenticator: Authenticator {
	func authenticate(reason: String) async -> AuthenticatorResult {
		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			return .failed(error?.localizedDescription ?? String(localized: "Touch ID isn't available."))
		}
		do {
			let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
			return ok ? .success : .failed(String(localized: "Touch ID didn't match."))
		} catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
			return .cancelled
		} catch {
			return .failed(error.localizedDescription)
		}
	}
}

/// `AccountSignIn` over the Keychain, with the system web sheet.
struct LiveAccountSigningIn: AccountSigningIn {
	private let store = KeychainAccountTokenStore(service: AccountSettingsKeys.keychainService)

	@MainActor
	private static func anchor() -> ASPresentationAnchor {
		NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
	}

	private func session(_ configuration: OIDCConfiguration?) -> AccountSignIn {
		AccountSignIn(
			configuration: configuration,
			authenticator: SystemWebAuthenticator(prefersEphemeralSession: true, anchor: { Self.anchor() }),
			store: store)
	}

	func signIn(configuration: OIDCConfiguration) async throws -> AccountCredential {
		try await session(configuration).signIn()
	}

	func useServerToken(_ token: String) async throws -> AccountCredential {
		try await session(nil).useServerToken(token)
	}

	/// Refreshes against the issuer the stored tokens came from.
	func validBearer() async throws -> String {
		guard let credential = try store.load() else { throw AccountError.notSignedIn }
		switch credential {
		case .staticToken(let token):
			return token
		case .oidc(let tokens):
			return try await session(.custom(issuer: tokens.issuer, clientID: tokens.clientID)).validBearer()
		}
	}

	func credential() async -> AccountCredential? { try? store.load() }

	func signOut() async throws { try store.clear() }
}

struct LiveAccountDirectory: AccountDirectory {
	func devices(baseURL: URL, bearer: String) async throws -> [PublicDevice] {
		try await RelayClient.devices(baseURL: baseURL, accountToken: bearer)
	}

	func revoke(baseURL: URL, bearer: String, deviceID: String) async throws {
		try await RelayClient.revoke(baseURL: baseURL, accountToken: bearer, deviceID: deviceID)
	}
}

/// The helper's Mach service.
struct XPCHelperAccountLink: HelperAccountLinking {
	func setAccount(bearer: String, backendURL: URL) async -> HelperAccountStatus? {
		let request = (try? JSONSerialization.data(withJSONObject: [
			"bearer": bearer, "backend_url": backendURL.absoluteString,
		])) ?? Data()
		return await MacLinkHelper.call(timeout: 45) { $0.setAccount(request, reply: $1) }
			.flatMap(HelperAccountStatus.decode)
	}

	func clearAccount() async -> HelperAccountStatus? {
		await MacLinkHelper.call(timeout: 30) { $0.clearAccount(reply: $1) }.flatMap(HelperAccountStatus.decode)
	}

	func accountStatus() async -> HelperAccountStatus? {
		await MacLinkHelper.call { $0.accountStatus(reply: $1) }.flatMap(HelperAccountStatus.decode)
	}

	func pendingConfirmations() async -> [PendingApproveConfirmation]? {
		await MacLinkHelper.call { $0.pendingApproveConfirmations(reply: $1) }
			.flatMap(PendingApproveConfirmation.decodeList)
	}

	func confirmApprove(deviceID: String) async -> Bool {
		guard let data = await MacLinkHelper.call(timeout: 30, { $0.confirmApprove(deviceID, reply: $1) }),
			let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else { return false }
		return object["ok"] as? Bool == true
	}
}

// MARK: - Account settings model

/// One device of the account, as the Account pane lists it.
struct AccountDeviceRow: Identifiable, Equatable {
	let id: String
	let name: String
	let platform: Platform
	/// `xxxx-xxxx-xxxx-xxxx` of the link key.
	let fingerprint: String
	let isRevoked: Bool
	/// Its keys did not verify against the fingerprints the backend advertises.
	let isUntrusted: Bool
	let isThisMac: Bool

	init(_ device: PublicDevice, thisMac: String?) {
		id = device.device_id
		name = device.name
		platform = device.platform
		let trusted = device.isRevoked ? nil : try? TrustedDevice(verifying: device)
		fingerprint = trusted?.displayFingerprint ?? LinkCrypto.displayFingerprint(device.link_fp)
		isRevoked = device.isRevoked
		isUntrusted = !device.isRevoked && trusted == nil
		isThisMac = device.device_id == thisMac
	}

	var platformName: String {
		switch platform {
		case .ios: return "iPhone"
		case .macos: return "Mac"
		case .linux: return "Linux"
		case .other: return String(localized: "Other")
		}
	}

	var systemImage: String {
		switch platform {
		case .ios: return "iphone"
		case .macos: return "laptopcomputer"
		case .linux, .other: return "desktopcomputer"
		}
	}
}

@MainActor
@Observable
final class AccountSettingsModel {
	static let shared = AccountSettingsModel()

	var provider: AccountProvider {
		didSet { defaults.set(provider.rawValue, forKey: AccountSettingsKeys.provider) }
	}
	var customIssuer: String {
		didSet { defaults.set(customIssuer, forKey: AccountSettingsKeys.customIssuer) }
	}
	var customClientID: String {
		didSet { defaults.set(customClientID, forKey: AccountSettingsKeys.customClientID) }
	}
	var backendURL: String {
		didSet { defaults.set(backendURL, forKey: AccountSettingsKeys.backendURL) }
	}
	var serverToken = ""

	private(set) var credential: AccountCredential?
	private(set) var devices: [AccountDeviceRow] = []
	private(set) var helperStatus: HelperAccountStatus?
	private(set) var isWorking = false
	var lastError: String?

	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let signIn: AccountSigningIn
	@ObservationIgnored private let directory: AccountDirectory
	@ObservationIgnored private let helper: HelperAccountLinking
	@ObservationIgnored private let hostedClientID: () -> String

	init(
		defaults: UserDefaults = .standard, signIn: AccountSigningIn = LiveAccountSigningIn(),
		directory: AccountDirectory = LiveAccountDirectory(), helper: HelperAccountLinking = XPCHelperAccountLink(),
		hostedClientID: (() -> String)? = nil
	) {
		self.defaults = defaults
		self.signIn = signIn
		self.directory = directory
		self.helper = helper
		self.hostedClientID = hostedClientID ?? { AccountSettingsKeys.hostedClientID(defaults: defaults) }
		provider = defaults.string(forKey: AccountSettingsKeys.provider).flatMap(AccountProvider.init) ?? .hosted
		customIssuer = defaults.string(forKey: AccountSettingsKeys.customIssuer) ?? ""
		customClientID = defaults.string(forKey: AccountSettingsKeys.customClientID) ?? "whispera"
		backendURL = defaults.string(forKey: AccountSettingsKeys.backendURL) ?? AccountSettingsKeys.defaultBackendURL
	}

	var isSignedIn: Bool { credential != nil }

	/// What the signed-in row says: the account subject, or that a server token is in use.
	var accountLabel: String {
		switch credential {
		case .oidc(let tokens): return tokens.subject ?? tokens.issuer.host ?? String(localized: "Signed in")
		case .staticToken: return String(localized: "Server token")
		case nil: return String(localized: "Not signed in")
		}
	}

	var hostedSignInAvailable: Bool { !hostedClientID().isEmpty }

	var canSignIn: Bool {
		guard !isWorking else { return false }
		switch provider {
		case .hosted: return hostedSignInAvailable
		case .custom: return issuerURL != nil && !customClientID.trimmingCharacters(in: .whitespaces).isEmpty
		case .serverToken: return !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}
	}

	var thisMacID: String? { helperStatus?.deviceID }

	/// The helper's account state, for the Account pane.
	var helperSummary: String {
		guard let status = helperStatus else { return String(localized: "The Mac link isn't running.") }
		switch status.status {
		case "registered": return String(localized: "This Mac is on your account.")
		case "revoked": return String(localized: "This Mac was removed from your account. Sign in again to add it back.")
		default: return String(localized: "This Mac hasn't joined your account yet.")
		}
	}

	private var issuerURL: URL? {
		let text = customIssuer.trimmingCharacters(in: .whitespaces)
		guard let url = URL(string: text), OIDCConfiguration.isAcceptableEndpoint(url) else { return nil }
		return url
	}

	var backend: URL? {
		var text = backendURL.trimmingCharacters(in: .whitespaces)
		while text.hasSuffix("/") { text.removeLast() }
		guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			url.host != nil
		else { return nil }
		return url
	}

	func configuration() -> OIDCConfiguration? {
		switch provider {
		case .hosted:
			let id = hostedClientID()
			return id.isEmpty ? nil : .hostedClerk(clientID: id, redirectURI: OIDCConfiguration.macRedirectURI)
		case .custom:
			guard let issuer = issuerURL else { return nil }
			return .custom(
				issuer: issuer, clientID: customClientID.trimmingCharacters(in: .whitespaces),
				redirectURI: OIDCConfiguration.macRedirectURI)
		case .serverToken:
			return nil
		}
	}

	/// Reads the stored credential and, when signed in, the helper's state and the device list.
	func load() async {
		credential = await signIn.credential()
		helperStatus = await helper.accountStatus()
		if isSignedIn { await refreshDevices() }
	}

	/// At launch: a signed-in Mac hands its bearer to the helper again (no-op when registered).
	func handOffAtLaunch() async {
		credential = await signIn.credential()
		guard isSignedIn else { return }
		await handOffToHelper()
	}

	func signInTapped() async {
		guard canSignIn else { return }
		isWorking = true
		defer { isWorking = false }
		do {
			if provider == .serverToken {
				credential = try await signIn.useServerToken(serverToken)
				serverToken = ""
			} else {
				guard let configuration = configuration() else { return }
				credential = try await signIn.signIn(configuration: configuration)
			}
			lastError = nil
			AppLogger.shared.general.info("Account sign-in finished (\(self.provider.rawValue))")
		} catch AccountError.cancelled {
			return
		} catch {
			lastError = error.localizedDescription
			AppLogger.shared.general.error("Account sign-in failed: \(error.localizedDescription)")
			return
		}
		await handOffToHelper()
		await refreshDevices()
	}

	/// Gives the helper the bearer so it joins the account (it registers this Mac only once).
	func handOffToHelper() async {
		guard let backend else {
			lastError = String(localized: "Enter a valid backend URL.")
			return
		}
		do {
			let bearer = try await signIn.validBearer()
			guard let status = await helper.setAccount(bearer: bearer, backendURL: backend) else {
				helperStatus = nil
				return
			}
			helperStatus = status
			if !status.ok {
				lastError = status.error?.message ?? status.error?.code
				AppLogger.shared.general.error("Mac link could not join the account: \(status.error?.code ?? "unknown")")
			}
		} catch {
			lastError = error.localizedDescription
		}
	}

	func refreshDevices() async {
		guard let backend else { return }
		do {
			let bearer = try await signIn.validBearer()
			let listed = try await directory.devices(baseURL: backend, bearer: bearer)
			let me = thisMacID
			// This Mac first, revoked devices last, the backend's order otherwise.
			devices = listed.enumerated()
				.map { (index: $0.offset, row: AccountDeviceRow($0.element, thisMac: me)) }
				.sorted {
					($0.row.isRevoked ? 1 : 0, $0.row.isThisMac ? 0 : 1, $0.index)
						< ($1.row.isRevoked ? 1 : 0, $1.row.isThisMac ? 0 : 1, $1.index)
				}
				.map(\.row)
		} catch AccountError.reauthenticationRequired {
			credential = nil
			devices = []
			lastError = AccountError.reauthenticationRequired.localizedDescription
		} catch {
			lastError = error.localizedDescription
		}
	}

	func revoke(_ row: AccountDeviceRow) async {
		guard let backend, !row.isRevoked, !row.isThisMac else { return }
		isWorking = true
		defer { isWorking = false }
		do {
			let bearer = try await signIn.validBearer()
			try await directory.revoke(baseURL: backend, bearer: bearer, deviceID: row.id)
			AppLogger.shared.general.info("Revoked account device \(row.id)")
		} catch {
			lastError = error.localizedDescription
		}
		await refreshDevices()
	}

	/// Leaves the account: the helper unpairs the account's phones here, this Mac's device is
	/// revoked on the backend, and the credential is forgotten.
	func signOut() async {
		isWorking = true
		defer { isWorking = false }
		let macID = thisMacID
		if let backend, let macID, let bearer = try? await signIn.validBearer() {
			try? await directory.revoke(baseURL: backend, bearer: bearer, deviceID: macID)
		}
		helperStatus = await helper.clearAccount() ?? helperStatus
		try? await signIn.signOut()
		credential = nil
		devices = []
	}
}

// MARK: - Approve confirmation

/// The confirm cards: each iPhone the helper pinned from the account waits here until the owner
/// confirms it may approve secrets on this Mac.
@MainActor
@Observable
final class ApproveConfirmModel {
	static let shared = ApproveConfirmModel()

	private(set) var pending: [PendingApproveConfirmation] = []
	private(set) var confirmingID: String?
	var lastError: String?
	private var dismissed: Set<String> = []
	@ObservationIgnored private let helper: HelperAccountLinking
	@ObservationIgnored private let authenticator: Authenticator

	init(helper: HelperAccountLinking = XPCHelperAccountLink(), authenticator: Authenticator = LocalAuthenticator()) {
		self.helper = helper
		self.authenticator = authenticator
	}

	/// Cards to show: pending and not put off with "Not now" in this session.
	var visible: [PendingApproveConfirmation] { pending.filter { !dismissed.contains($0.deviceID) } }

	func refresh() async {
		pending = await helper.pendingConfirmations() ?? []
	}

	static func reason(for item: PendingApproveConfirmation) -> String {
		String(format: String(localized: "allow %@ to approve secrets on this Mac"), item.name)
	}

	/// Touch ID, then the helper marks the phone confirmed and tells it. Returns whether it was.
	@discardableResult
	func confirm(_ item: PendingApproveConfirmation) async -> Bool {
		guard confirmingID == nil else { return false }
		confirmingID = item.deviceID
		defer { confirmingID = nil }
		switch await authenticator.authenticate(reason: Self.reason(for: item)) {
		case .success:
			break
		case .cancelled:
			return false
		case .failed(let message):
			lastError = message
			return false
		}
		guard await helper.confirmApprove(deviceID: item.deviceID) else {
			lastError = String(localized: "The Mac link didn't accept the confirmation. Try again.")
			return false
		}
		AppLogger.shared.general.info("Confirmed approve rights for \(item.deviceID)")
		pending.removeAll { $0.deviceID == item.deviceID }
		await refresh()
		return true
	}

	func notNow(_ item: PendingApproveConfirmation) {
		dismissed.insert(item.deviceID)
	}
}
