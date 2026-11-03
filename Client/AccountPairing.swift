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

/// Where the account settings live. The hosted Clerk client id (a public PKCE client, no secret)
/// comes from the `WHISPERA_CLERK_CLIENT_ID` build setting (Info.plist `WhisperaClerkClientID`) and
/// can be overridden with the `whisperaAccountClerkClientID` default.
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

/// What the helper said to a confirmation.
enum HelperConfirmResult: Equatable, Sendable {
	case confirmed
	/// The device's keys are no longer the ones behind the safety number the owner compared.
	case keysChanged
	/// The phone never ran the committed safety-number exchange (an older Whispera on it).
	case peerUpdateRequired
	case failed(String?)

	/// Reads a `confirmApprove` / `approve.confirm` reply.
	static func decode(_ data: Data?) -> HelperConfirmResult {
		guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
			return .failed(nil)
		}
		if object["ok"] as? Bool == true { return .confirmed }
		let code = (object["error"] as? [String: Any])?["code"] as? String
		switch code {
		case "keys_changed": return .keysChanged
		case "peer_update_required": return .peerUpdateRequired
		default: return .failed(code)
		}
	}
}

/// The link helper's account calls (XPC).
protocol HelperAccountLinking: Sendable {
	func setAccount(bearer: String, backendURL: URL) async -> HelperAccountStatus?
	func clearAccount() async -> HelperAccountStatus?
	func accountStatus() async -> HelperAccountStatus?
	func pendingConfirmations() async -> [PendingApproveConfirmation]?
	/// `safetyNumber` is the one the card showed: the helper confirms only when it still matches
	/// the device's keys.
	func confirmApprove(deviceID: String, safetyNumber: String) async -> HelperConfirmResult
	/// Other Macs of the account waiting for the owner's "Link" here, and those linked already.
	func macLinks() async -> (pending: [PendingMacLink], linked: [PendingMacLink])?
	/// The owner's answer to a link card, an Unlink or a Relink: what the card showed.
	func decideLink(_ item: PendingMacLink, approve: Bool, relink: Bool) async -> HelperConfirmResult
	/// "Allow iPhone X?" on a vouched card: the owner's Touch ID, bound to the fingerprint and
	/// voucher shown.
	func confirmVouched(deviceID: String, linkFingerprint: String, vouchedBy: String) async -> HelperConfirmResult
}

extension HelperAccountLinking {
	func confirmVouched(deviceID: String, linkFingerprint: String, vouchedBy: String) async -> HelperConfirmResult {
		.failed(nil)
	}
	func macLinks() async -> (pending: [PendingMacLink], linked: [PendingMacLink])? { ([], []) }
	func decideLink(_ item: PendingMacLink, approve: Bool, relink: Bool) async -> HelperConfirmResult { .failed(nil) }
}

private func linkDecisionRequest(_ item: PendingMacLink, approve: Bool, relink: Bool = false) -> [String: Any] {
	[
		"device_id": item.deviceID, "decision": relink ? "relink" : (approve ? "approve" : "decline"),
		"tailnet_name": item.tailnetName, "link_fingerprint": item.linkFingerprint, "name": item.name,
		"node_id": item.nodeID ?? "",
	]
}

private func decodeMacLinks(_ data: Data?) -> (pending: [PendingMacLink], linked: [PendingMacLink])? {
	guard let data, let pending = PendingMacLink.decodeList(data) else { return nil }
	// A Mac that moved to another node shows once, as moved (Relink), not also as linked.
	let moved = (PendingMacLink.decodeMoved(data) ?? []).map { entry -> PendingMacLink in
		var flagged = entry
		flagged.keyChanged = true
		return flagged
	}
	let movedIDs = Set(moved.map(\.deviceID))
	return (pending, (PendingMacLink.decodeLinked(data) ?? []).filter { !movedIDs.contains($0.deviceID) } + moved)
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
	/// Touch ID where the Mac has it; the login password only where it has none.
	func authenticateBiometricFirst(reason: String) async -> AuthenticatorResult
	/// Touch ID only: fails where the Mac has none (the safety number is the way in then).
	func authenticateBiometricOnly(reason: String) async -> AuthenticatorResult
}

extension Authenticator {
	func authenticateBiometricFirst(reason: String) async -> AuthenticatorResult {
		await authenticate(reason: reason)
	}

	func authenticateBiometricOnly(reason: String) async -> AuthenticatorResult {
		await authenticate(reason: reason)
	}
}

// MARK: - Live implementations

/// `LAContext` owner authentication.
struct LocalAuthenticator: Authenticator {
	func authenticate(reason: String) async -> AuthenticatorResult {
		await evaluate(.deviceOwnerAuthentication, reason: reason)
	}

	func authenticateBiometricFirst(reason: String) async -> AuthenticatorResult {
		let policy: LAPolicy =
			LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
			? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
		return await evaluate(policy, reason: reason)
	}

	func authenticateBiometricOnly(reason: String) async -> AuthenticatorResult {
		guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
			return .failed(String(localized: "Touch ID isn't set up on this Mac. Compare the safety number instead."))
		}
		return await evaluate(.deviceOwnerAuthenticationWithBiometrics, reason: reason)
	}

	private func evaluate(_ policy: LAPolicy, reason: String) async -> AuthenticatorResult {
		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(policy, error: &error) else {
			return .failed(error?.localizedDescription ?? String(localized: "Touch ID isn't available."))
		}
		do {
			let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
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

	func confirmApprove(deviceID: String, safetyNumber: String) async -> HelperConfirmResult {
		HelperConfirmResult.decode(
			await MacLinkHelper.call(timeout: 30, { $0.confirmApprove(deviceID, safetyNumber: safetyNumber, reply: $1) }))
	}

	func macLinks() async -> (pending: [PendingMacLink], linked: [PendingMacLink])? {
		decodeMacLinks(await MacLinkHelper.call { $0.pendingLinks(reply: $1) })
	}

	func confirmVouched(deviceID: String, linkFingerprint: String, vouchedBy: String) async -> HelperConfirmResult {
		let request =
			(try? JSONSerialization.data(
				withJSONObject: ["device_id": deviceID, "link_fingerprint": linkFingerprint, "vouched_by": vouchedBy])) ?? Data()
		return HelperConfirmResult.decode(await MacLinkHelper.call(timeout: 30) { $0.confirmVouched(request, reply: $1) })
	}

	func decideLink(_ item: PendingMacLink, approve: Bool, relink: Bool) async -> HelperConfirmResult {
		let request =
			(try? JSONSerialization.data(withJSONObject: linkDecisionRequest(item, approve: approve, relink: relink))) ?? Data()
		return HelperConfirmResult.decode(await MacLinkHelper.call(timeout: 30) { $0.decideLink(request, reply: $1) })
	}
}

/// Which helper and authenticator the shared models use. Release builds: XPC and Touch ID,
/// always.
enum AccountLinkEnvironment {
	static func helper(environment: [String: String] = ProcessInfo.processInfo.environment)
		-> HelperAccountLinking
	{
		#if DEBUG
			// Screen recordings and manual checks: talk to a standalone e2e helper
			// (LinkHelper/e2e/account-pairing.sh serve) over its admin socket, never the
			// installed helper.
			if let path = environment["WHISPERA_E2E_ADMIN_SOCKET"], !path.isEmpty {
				AppLogger.shared.general.info("Account link: using the e2e helper at \(path) (debug build)")
				return AdminSocketHelperAccountLink(path: path)
			}
		#endif
		return XPCHelperAccountLink()
	}

	static func authenticator(environment: [String: String] = ProcessInfo.processInfo.environment)
		-> Authenticator
	{
		#if DEBUG
			if environment["WHISPERA_TEST_AUTHENTICATOR"] == "allow" {
				AppLogger.shared.general.info("Account link: owner authentication is faked (debug build)")
				return AllowingTestAuthenticator()
			}
		#endif
		return LocalAuthenticator()
	}
}

#if DEBUG
	/// Debug builds only (`WHISPERA_TEST_AUTHENTICATOR=allow`): every owner check passes, so a
	/// confirmation can be recorded without a real Touch ID.
	struct AllowingTestAuthenticator: Authenticator {
		func authenticate(reason: String) async -> AuthenticatorResult {
			try? await Task.sleep(nanoseconds: 600_000_000)
			return .success
		}
	}

	/// Debug builds only (`WHISPERA_E2E_ADMIN_SOCKET`): the account calls over a standalone e2e
	/// helper's admin socket, one JSON line each way. `approve.confirm` there needs the helper's
	/// test flag (`WLH_TEST_CONFIRM=1`, the script's default).
	struct AdminSocketHelperAccountLink: HelperAccountLinking {
		let path: String

		func request(_ object: [String: Any]) async -> Data? {
			let path = self.path
			return await Task.detached { Self.exchange(object, path: path) }.value
		}

		static func exchange(_ object: [String: Any], path: String) -> Data? {
			guard var line = try? JSONSerialization.data(withJSONObject: object) else { return nil }
			line.append(0x0A)
			let fd = socket(AF_UNIX, SOCK_STREAM, 0)
			guard fd >= 0 else { return nil }
			defer { close(fd) }
			var timeout = timeval(tv_sec: 60, tv_usec: 0)
			setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
			var address = sockaddr_un()
			address.sun_family = sa_family_t(AF_UNIX)
			let bytes = Array(path.utf8)
			guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
			withUnsafeMutableBytes(of: &address.sun_path) { buffer in
				buffer.copyBytes(from: bytes)
				buffer[bytes.count] = 0
			}
			let connected = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
				}
			}
			guard connected == 0 else { return nil }
			let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
			guard sent == line.count else { return nil }
			var reply = Data()
			var chunk = [UInt8](repeating: 0, count: 65536)
			while !reply.contains(0x0A) {
				let count = read(fd, &chunk, chunk.count)
				guard count > 0 else { break }
				reply.append(contentsOf: chunk[0..<count])
			}
			return reply.isEmpty ? nil : reply
		}

		func setAccount(bearer: String, backendURL: URL) async -> HelperAccountStatus? {
			await request(["op": "account.set", "bearer": bearer, "backend_url": backendURL.absoluteString])
				.flatMap(HelperAccountStatus.decode)
		}

		func clearAccount() async -> HelperAccountStatus? {
			await request(["op": "account.clear"]).flatMap(HelperAccountStatus.decode)
		}

		func accountStatus() async -> HelperAccountStatus? {
			await request(["op": "account.status"]).flatMap(HelperAccountStatus.decode)
		}

		func pendingConfirmations() async -> [PendingApproveConfirmation]? {
			await request(["op": "approve.pending"]).flatMap(PendingApproveConfirmation.decodeList)
		}

		func confirmApprove(deviceID: String, safetyNumber: String) async -> HelperConfirmResult {
			HelperConfirmResult.decode(
				await request(["op": "approve.confirm", "device_id": deviceID, "safety_number": safetyNumber]))
		}

		func macLinks() async -> (pending: [PendingMacLink], linked: [PendingMacLink])? {
			decodeMacLinks(await request(["op": "link.pending"]))
		}

		func confirmVouched(deviceID: String, linkFingerprint: String, vouchedBy: String) async -> HelperConfirmResult {
			HelperConfirmResult.decode(
				await request([
					"op": "approve.confirm_vouched", "device_id": deviceID, "link_fingerprint": linkFingerprint,
					"vouched_by": vouchedBy,
				]))
		}

		func decideLink(_ item: PendingMacLink, approve: Bool, relink: Bool) async -> HelperConfirmResult {
			var body = linkDecisionRequest(item, approve: approve, relink: relink)
			body["op"] = "link.decide"
			return HelperConfirmResult.decode(await request(body))
		}
	}
#endif

// MARK: - Account settings model

/// One device of the account, as the Account pane lists it.
struct AccountDeviceRow: Identifiable, Equatable {
	let id: String
	let name: String
	let platform: Platform
	/// `xxxx-xxxx-xxxx-xxxx` of the link key.
	let fingerprint: String
	/// Its keys did not verify against the fingerprints the backend advertises.
	let isUntrusted: Bool
	let isThisMac: Bool
	/// iPhones pinned by this Mac's link: what approval pushes say (`named` / `generic`).
	var pushText: String?
	/// The iPhone that made the latest request here; approvals push to it first.
	var isLastUsed = false

	init(_ device: PublicDevice, thisMac: String?, detail: HelperAccountStatus.PhoneDetail? = nil) {
		id = device.device_id
		name = device.name
		platform = device.platform
		let trusted = device.isRevoked ? nil : try? TrustedDevice(verifying: device)
		fingerprint = trusted?.displayFingerprint ?? LinkCrypto.displayFingerprint(device.link_fp)
		isUntrusted = !device.isRevoked && trusted == nil
		isThisMac = device.device_id == thisMac
		pushText = detail?.pushText
		isLastUsed = detail?.lastUsed ?? false
	}

	/// "Push: named" / "Push: generic" for an iPhone the link knows.
	var pushTextLabel: String? {
		switch pushText {
		case "named": return String(localized: "Push: named")
		case "generic": return String(localized: "Push: generic")
		default: return nil
		}
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
	static let shared = AccountSettingsModel(helper: AccountLinkEnvironment.helper())

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
			let status = helperStatus
			// Revoked devices are not listed; this Mac first, the backend's order otherwise.
			devices = listed.enumerated()
				.filter { !$0.element.isRevoked }
				.map {
					(
						index: $0.offset,
						row: AccountDeviceRow(
							$0.element, thisMac: me, detail: status?.phoneDetail($0.element.device_id))
					)
				}
				.sorted {
					($0.row.isThisMac ? 0 : 1, $0.index) < ($1.row.isThisMac ? 0 : 1, $1.index)
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
		guard let backend, !row.isThisMac else { return }
		isWorking = true
		defer { isWorking = false }
		do {
			let bearer = try await signIn.validBearer()
			try await directory.revoke(baseURL: backend, bearer: bearer, deviceID: row.id)
			devices.removeAll { $0.id == row.id }
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
	static let shared = ApproveConfirmModel(
		helper: AccountLinkEnvironment.helper(), authenticator: AccountLinkEnvironment.authenticator())

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

	/// Touch ID, then the helper confirms the phone, bound to the safety number the card showed
	/// (it refuses if the phone's keys changed since). Returns whether it did.
	@discardableResult
	func confirm(_ item: PendingApproveConfirmation) async -> Bool {
		guard confirmingID == nil else { return false }
		guard let safetyNumber = item.safetyNumber, !safetyNumber.isEmpty else {
			lastError = String(localized: "The Mac link didn't send a safety number for this iPhone. Try again.")
			return false
		}
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
		switch await helper.confirmApprove(deviceID: item.deviceID, safetyNumber: safetyNumber) {
		case .confirmed:
			break
		case .keysChanged:
			lastError = String(
				localized: "This iPhone's keys changed while the card was open. Compare the new safety number before you confirm.")
			await refresh()
			return false
		case .peerUpdateRequired:
			lastError = String(
				localized: "This iPhone hasn't sent a safety number this Mac can check. Update Whispera on the iPhone and open it.")
			await refresh()
			return false
		case .failed:
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

	/// "Allow iPhone X, vouched by Mac Y?": Touch ID only (no password fallback), then the helper
	/// confirms, bound to the fingerprint the card showed and a vouch that still holds.
	@discardableResult
	func confirmVouched(_ item: PendingApproveConfirmation) async -> Bool {
		guard confirmingID == nil, let voucherID = item.vouchedBy, let fingerprint = item.linkFingerprint else { return false }
		confirmingID = item.deviceID
		defer { confirmingID = nil }
		let voucher = item.vouchedByName ?? String(localized: "your other Mac")
		let reason = String(format: String(localized: "allow %@, vouched by %@, to approve secrets on this Mac"), item.name, voucher)
		switch await authenticator.authenticateBiometricOnly(reason: reason) {
		case .success:
			break
		case .cancelled:
			return false
		case .failed(let message):
			lastError = message
			return false
		}
		switch await helper.confirmVouched(deviceID: item.deviceID, linkFingerprint: fingerprint, vouchedBy: voucherID) {
		case .confirmed:
			break
		case .keysChanged:
			lastError = String(localized: "The vouch for this iPhone no longer holds. Compare the safety number instead.")
			await refresh()
			return false
		case .failed, .peerUpdateRequired:
			lastError = String(localized: "The Mac link didn't accept the confirmation. Try again.")
			return false
		}
		AppLogger.shared.general.info("Confirmed vouched iPhone \(item.deviceID)")
		pending.removeAll { $0.deviceID == item.deviceID }
		await refresh()
		return true
	}
}

// MARK: - Linking another Mac

/// The "Link this Mac?" cards: another Mac of the account proved its key from a node of the
/// owner's tailnet. Linking it (one Touch ID, no number to compare) lets it and this Mac trust
/// each other's devices; the tailnet proof alone grants nothing.
@MainActor
@Observable
final class MacLinkModel {
	static let shared = MacLinkModel(
		helper: AccountLinkEnvironment.helper(), authenticator: AccountLinkEnvironment.authenticator())

	private(set) var pending: [PendingMacLink] = []
	/// Macs linked here: an Unlink row each.
	private(set) var linked: [PendingMacLink] = []
	private(set) var decidingID: String?
	var lastError: String?
	private var dismissed: Set<String> = []
	@ObservationIgnored private let helper: HelperAccountLinking
	@ObservationIgnored private let authenticator: Authenticator

	init(helper: HelperAccountLinking = XPCHelperAccountLink(), authenticator: Authenticator = LocalAuthenticator()) {
		self.helper = helper
		self.authenticator = authenticator
	}

	var visible: [PendingMacLink] { pending.filter { !dismissed.contains($0.deviceID) } }

	func refresh() async {
		guard let answer = await helper.macLinks() else { return }
		pending = answer.pending
		linked = answer.linked
	}

	static func reason(for item: PendingMacLink) -> String {
		String(format: String(localized: "link %@ (%@) with your devices"), item.tailnetName, item.name)
	}

	static func unlinkReason(for item: PendingMacLink) -> String {
		String(format: String(localized: "unlink %@ (%@)"), item.tailnetName, item.name)
	}

	/// Touch ID, then the helper links the Mac, bound to the tailnet name the card showed.
	@discardableResult
	func link(_ item: PendingMacLink) async -> Bool {
		guard decidingID == nil else { return false }
		decidingID = item.deviceID
		defer { decidingID = nil }
		guard await owner(Self.reason(for: item)) else { return false }
		switch await helper.decideLink(item, approve: true, relink: false) {
		case .confirmed:
			break
		case .keysChanged:
			lastError = String(localized: "This Mac changed while the card was open. Check the new card before you link it.")
			await refresh()
			return false
		case .failed, .peerUpdateRequired:
			lastError = String(localized: "The Mac link didn't accept the link. Try again.")
			return false
		}
		AppLogger.shared.general.info("Linked Mac \(item.deviceID)")
		pending.removeAll { $0.deviceID == item.deviceID }
		await refresh()
		return true
	}

	/// "Don't Link" on a card, or "Unlink" on a linked Mac: after the owner's Touch ID too (an
	/// unlink takes trust away), the helper declines the Mac for these keys; its card stays away.
	func decline(_ item: PendingMacLink) async {
		guard decidingID == nil else { return }
		decidingID = item.deviceID
		defer { decidingID = nil }
		guard await owner(Self.unlinkReason(for: item)) else { return }
		if case .confirmed = await helper.decideLink(item, approve: false, relink: false) {
			pending.removeAll { $0.deviceID == item.deviceID }
			linked.removeAll { $0.deviceID == item.deviceID }
			await refresh()
		} else {
			lastError = String(localized: "The Mac link didn't take the answer. Try again.")
		}
	}

	/// "Relink": after Touch ID, the helper forgets this Mac's tailnet node (it moved, say after a
	/// Tailscale re-login) without declining it; its Link card comes back for the new node.
	func relink(_ item: PendingMacLink) async {
		guard decidingID == nil else { return }
		decidingID = item.deviceID
		defer { decidingID = nil }
		guard await owner(String(format: String(localized: "relink %@"), item.name)) else { return }
		if case .confirmed = await helper.decideLink(item, approve: false, relink: true) {
			await refresh()
		} else {
			lastError = String(localized: "The Mac link didn't take the answer. Try again.")
		}
	}

	private func owner(_ reason: String) async -> Bool {
		switch await authenticator.authenticateBiometricFirst(reason: reason) {
		case .success:
			return true
		case .cancelled:
			return false
		case .failed(let message):
			lastError = message
			return false
		}
	}

	func notNow(_ item: PendingMacLink) {
		dismissed.insert(item.deviceID)
	}
}
