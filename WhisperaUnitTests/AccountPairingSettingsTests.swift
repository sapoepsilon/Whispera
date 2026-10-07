import AppKit
import Foundation
import LinkHelperXPC
import SwiftUI
import Testing
import WhisperaAccount
import WhisperaLink

@testable import Whispera

// MARK: - Fakes

final class FakeAccountSigningIn: AccountSigningIn, @unchecked Sendable {
	private let lock = NSLock()
	private var stored: AccountCredential?
	private(set) var signInConfigurations: [OIDCConfiguration] = []
	var signInError: Error?

	init(_ credential: AccountCredential? = nil) {
		stored = credential
	}

	func signIn(configuration: OIDCConfiguration) async throws -> AccountCredential {
		lock.lock()
		defer { lock.unlock() }
		signInConfigurations.append(configuration)
		if let signInError { throw signInError }
		let credential = AccountCredential.oidc(
			OIDCTokens(
				issuer: configuration.issuer, clientID: configuration.clientID, accessToken: "access",
				idToken: "id-token", subject: "alice"))
		stored = credential
		return credential
	}

	func useServerToken(_ token: String) async throws -> AccountCredential {
		lock.lock()
		defer { lock.unlock() }
		stored = .staticToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
		return stored!
	}

	func validBearer() async throws -> String {
		lock.lock()
		defer { lock.unlock() }
		guard let stored else { throw AccountError.notSignedIn }
		return stored.bearer(.idToken) ?? ""
	}

	func credential() async -> AccountCredential? {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}

	func signOut() async throws {
		lock.lock()
		stored = nil
		lock.unlock()
	}
}

final class FakeAccountDirectory: AccountDirectory, @unchecked Sendable {
	private let lock = NSLock()
	var listed: [PublicDevice]
	private(set) var revoked: [String] = []
	private(set) var bearers: [String] = []

	init(_ devices: [PublicDevice] = []) {
		listed = devices
	}

	func devices(baseURL: URL, bearer: String) async throws -> [PublicDevice] {
		lock.lock()
		defer { lock.unlock() }
		bearers.append(bearer)
		return listed
	}

	func revoke(baseURL: URL, bearer: String, deviceID: String) async throws {
		lock.lock()
		defer { lock.unlock() }
		revoked.append(deviceID)
		if let index = listed.firstIndex(where: { $0.device_id == deviceID }) { listed[index].revoked_at = 1 }
	}
}

final class FakeHelperAccountLink: HelperAccountLinking, @unchecked Sendable {
	private let lock = NSLock()
	var macID = "dev_aaaaaaaaaaaaaaaaaaaaaaaa"
	var pending: [PendingApproveConfirmation] = []
	private(set) var handedOff: [(bearer: String, backend: URL)] = []
	private(set) var confirmed: [String] = []
	private(set) var cleared = 0
	var confirmSucceeds = true
	var registered = false

	private func status() -> HelperAccountStatus {
		HelperAccountStatus(
			ok: true, status: registered ? "registered" : "signed_out", deviceID: registered ? macID : nil,
			baseURL: nil, lastSyncAt: nil, lastError: nil, phones: [], pendingConfirmations: pending.count, error: nil)
	}

	func setAccount(bearer: String, backendURL: URL) async -> HelperAccountStatus? {
		lock.lock()
		defer { lock.unlock() }
		handedOff.append((bearer, backendURL))
		registered = true
		return status()
	}

	func clearAccount() async -> HelperAccountStatus? {
		lock.lock()
		defer { lock.unlock() }
		cleared += 1
		registered = false
		return status()
	}

	func accountStatus() async -> HelperAccountStatus? {
		lock.lock()
		defer { lock.unlock() }
		return status()
	}

	func pendingConfirmations() async -> [PendingApproveConfirmation]? {
		lock.lock()
		defer { lock.unlock() }
		return pending
	}

	func confirmApprove(deviceID: String) async -> Bool {
		lock.lock()
		defer { lock.unlock() }
		confirmed.append(deviceID)
		guard confirmSucceeds else { return false }
		pending.removeAll { $0.deviceID == deviceID }
		return true
	}
}

struct FakeAuthenticator: Authenticator {
	let result: AuthenticatorResult

	func authenticate(reason: String) async -> AuthenticatorResult { result }
}

enum AccountFixtures {
	/// A device whose keys verify, as the backend would list it.
	static func device(
		_ id: String, name: String, platform: Platform, revoked: Bool = false
	) throws -> PublicDevice {
		let link = SoftwareSigningKey()
		let approve = SoftwareSigningKey()
		let kem = SoftwareAgreementKey()
		let request = try AccountDeviceRegistration.request(
			name: name, platform: platform, linkKey: link, approveKey: platform == .ios ? approve.publicKey : nil,
			agreementKey: kem.publicKey)
		return PublicDevice(
			device_id: id, name: name, platform: platform, link_pubkey: request.link_pubkey,
			approve_pubkey: request.approve_pubkey, kem_pubkey: request.kem_pubkey,
			link_fp: link.publicKey.fingerprint, approve_fp: request.approve_pubkey == nil ? nil : approve.publicKey.fingerprint,
			created_at: 1_790_000_000, revoked_at: revoked ? 1_790_000_100 : nil)
	}

	static let pendingPhone = PendingApproveConfirmation(
		deviceID: "dev_bbbbbbbbbbbbbbbbbbbbbbbb", name: "Uzi's iPhone", fingerprint: "835d-7c2e-6f8d-1ac5",
		approveFP: String(repeating: "a", count: 64))

	static func defaults() -> UserDefaults {
		UserDefaults(suiteName: "AccountPairingSettingsTests.\(UUID().uuidString)")!
	}
}

// MARK: - Confirm card

@MainActor
struct ApproveConfirmModelTests {
	@Test func touchIDSuccessConfirmsTheIPhoneWithTheHelper() async {
		let helper = FakeHelperAccountLink()
		helper.pending = [AccountFixtures.pendingPhone]
		let model = ApproveConfirmModel(helper: helper, authenticator: FakeAuthenticator(result: .success))
		await model.refresh()
		#expect(model.visible.map(\.deviceID) == [AccountFixtures.pendingPhone.deviceID])

		let confirmed = await model.confirm(AccountFixtures.pendingPhone)
		#expect(confirmed)
		#expect(helper.confirmed == [AccountFixtures.pendingPhone.deviceID])
		#expect(model.visible.isEmpty)
		#expect(model.lastError == nil)
	}

	@Test(arguments: [AuthenticatorResult.cancelled, .failed("Touch ID didn't match.")])
	func touchIDCancelOrFailureNeverConfirms(result: AuthenticatorResult) async {
		let helper = FakeHelperAccountLink()
		helper.pending = [AccountFixtures.pendingPhone]
		let model = ApproveConfirmModel(helper: helper, authenticator: FakeAuthenticator(result: result))
		await model.refresh()

		let confirmed = await model.confirm(AccountFixtures.pendingPhone)
		#expect(!confirmed)
		#expect(helper.confirmed.isEmpty)
		#expect(model.visible.count == 1)
		#expect((model.lastError != nil) == (result != .cancelled))
	}

	@Test func aHelperThatRefusesLeavesTheCardUp() async {
		let helper = FakeHelperAccountLink()
		helper.pending = [AccountFixtures.pendingPhone]
		helper.confirmSucceeds = false
		let model = ApproveConfirmModel(helper: helper, authenticator: FakeAuthenticator(result: .success))
		await model.refresh()
		#expect(!(await model.confirm(AccountFixtures.pendingPhone)))
		#expect(model.visible.count == 1)
		#expect(model.lastError != nil)
	}

	@Test func notNowHidesTheCardForThisSessionOnly() async {
		let helper = FakeHelperAccountLink()
		helper.pending = [AccountFixtures.pendingPhone]
		let model = ApproveConfirmModel(helper: helper, authenticator: FakeAuthenticator(result: .success))
		await model.refresh()
		model.notNow(AccountFixtures.pendingPhone)
		#expect(model.visible.isEmpty)
		#expect(helper.confirmed.isEmpty)
		#expect(model.pending.count == 1, "still pending in the helper")
	}

	@Test func theTouchIDReasonNamesTheIPhone() {
		#expect(ApproveConfirmModel.reason(for: AccountFixtures.pendingPhone).contains("Uzi's iPhone"))
	}
}

// MARK: - Account settings

@MainActor
struct AccountSettingsModelTests {
	@Test func serverTokenSignInHandsTheBearerAndBackendToTheHelper() async throws {
		let signIn = FakeAccountSigningIn()
		let helper = FakeHelperAccountLink()
		let defaults = AccountFixtures.defaults()
		let model = AccountSettingsModel(
			defaults: defaults, signIn: signIn, directory: FakeAccountDirectory(), helper: helper,
			hostedClientID: { "" })
		#expect(model.backendURL == "https://api.mansurov.dev")
		model.provider = .serverToken
		#expect(!model.canSignIn)
		model.serverToken = "  srv-token \n"
		#expect(model.canSignIn)
		model.backendURL = "http://127.0.0.1:18080/"

		await model.signInTapped()
		#expect(model.isSignedIn)
		#expect(model.serverToken.isEmpty)
		#expect(helper.handedOff.map(\.bearer) == ["srv-token"])
		#expect(helper.handedOff.map(\.backend.absoluteString) == ["http://127.0.0.1:18080"])
		#expect(model.thisMacID == helper.macID)
		#expect(defaults.string(forKey: AccountSettingsKeys.provider) == "serverToken")
	}

	@Test func customIssuerNeedsHTTPSOrLoopbackAndUsesTheMacCallback() async throws {
		let signIn = FakeAccountSigningIn()
		let model = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: signIn, directory: FakeAccountDirectory(),
			helper: FakeHelperAccountLink(), hostedClientID: { "" })
		model.provider = .custom
		model.customIssuer = "http://auth.example.com"
		#expect(!model.canSignIn)
		model.customIssuer = "http://127.0.0.1:18081"
		model.customClientID = "whispera"
		#expect(model.canSignIn)

		await model.signInTapped()
		let configuration = try #require(signIn.signInConfigurations.first)
		#expect(configuration.issuer.absoluteString == "http://127.0.0.1:18081")
		#expect(configuration.redirectURI.absoluteString == "whispera-mac://auth/callback")
		#expect(model.accountLabel == "alice")
	}

	@Test func hostedSignInNeedsTheOwnerProvidedClientID() {
		let without = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: FakeAccountSigningIn(), directory: FakeAccountDirectory(),
			helper: FakeHelperAccountLink(), hostedClientID: { "" })
		#expect(without.provider == .hosted)
		#expect(!without.hostedSignInAvailable)
		#expect(!without.canSignIn)
		#expect(without.configuration() == nil)

		let with = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: FakeAccountSigningIn(), directory: FakeAccountDirectory(),
			helper: FakeHelperAccountLink(), hostedClientID: { "client_123" })
		#expect(with.canSignIn)
		#expect(with.configuration()?.issuer == OIDCConfiguration.hostedClerkIssuer)
		#expect(with.configuration()?.clientID == "client_123")
	}

	@Test func theClientIDDefaultOverridesAnUnsubstitutedPlistValue() {
		let defaults = AccountFixtures.defaults()
		#expect(AccountSettingsKeys.hostedClientID(defaults: defaults, bundle: Bundle(for: BundleToken.self)) == "")
		defaults.set("client_override", forKey: AccountSettingsKeys.clerkClientID)
		#expect(AccountSettingsKeys.hostedClientID(defaults: defaults) == "client_override")
	}

	@Test func devicesListTheAccountWithThisMacFirstAndRevokedLast() async throws {
		let helper = FakeHelperAccountLink()
		helper.registered = true
		let mac = try AccountFixtures.device(helper.macID, name: "Studio Mac", platform: .macos)
		let phone = try AccountFixtures.device("dev_cccccccccccccccccccccccc", name: "iPhone", platform: .ios)
		let old = try AccountFixtures.device("dev_dddddddddddddddddddddddd", name: "Old iPhone", platform: .ios, revoked: true)
		var forged = try AccountFixtures.device("dev_eeeeeeeeeeeeeeeeeeeeeeee", name: "Forged", platform: .ios)
		forged.link_fp = String(repeating: "0", count: 64)
		let directory = FakeAccountDirectory([old, phone, forged, mac])
		let model = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: FakeAccountSigningIn(.staticToken("t")), directory: directory,
			helper: helper, hostedClientID: { "" })

		await model.load()
		#expect(model.devices.map(\.name) == ["Studio Mac", "iPhone", "Forged", "Old iPhone"])
		#expect(model.devices.first?.isThisMac == true)
		#expect(model.devices.last?.isRevoked == true)
		#expect(model.devices.first { $0.name == "Forged" }?.isUntrusted == true)
		#expect(model.devices.first { $0.name == "iPhone" }?.fingerprint.count == 19)

		// This Mac is never revoked from its own list: Sign out covers it.
		await model.revoke(try #require(model.devices.first { $0.isThisMac }))
		#expect(directory.revoked.isEmpty)

		await model.revoke(try #require(model.devices.first { $0.name == "iPhone" }))
		#expect(directory.revoked == [phone.device_id])
		#expect(model.devices.first { $0.name == "iPhone" }?.isRevoked == true)
	}

	@Test func signingOutRevokesThisMacAndClearsTheHelperAndTheCredential() async throws {
		let helper = FakeHelperAccountLink()
		helper.registered = true
		let directory = FakeAccountDirectory([try AccountFixtures.device(helper.macID, name: "Mac", platform: .macos)])
		let signIn = FakeAccountSigningIn(.staticToken("t"))
		let model = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: signIn, directory: directory, helper: helper,
			hostedClientID: { "" })
		await model.load()

		await model.signOut()
		#expect(directory.revoked == [helper.macID])
		#expect(helper.cleared == 1)
		#expect(!model.isSignedIn)
		#expect(model.devices.isEmpty)
		#expect(await signIn.credential() == nil)
	}

	@Test func aBadBackendURLIsReportedNotSent() async {
		let helper = FakeHelperAccountLink()
		let model = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: FakeAccountSigningIn(.staticToken("t")),
			directory: FakeAccountDirectory(), helper: helper, hostedClientID: { "" })
		model.backendURL = "not a url"
		await model.handOffToHelper()
		#expect(helper.handedOff.isEmpty)
		#expect(model.lastError != nil)
	}
}

private final class BundleToken {}

// MARK: - Snapshots

/// Renders the Account pane and the confirm card to PNG (no screen capture): the evidence for
/// step 11. Written to `WHISPERA_SNAPSHOT_DIR`, or a temp folder.
@MainActor
struct AccountPairingSnapshotTests {
	static var directory: URL {
		let path =
			ProcessInfo.processInfo.environment["WHISPERA_SNAPSHOT_DIR"]
			?? (NSTemporaryDirectory() as NSString).appendingPathComponent("whispera-account-snapshots")
		let url = URL(fileURLWithPath: path)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// Draws through an offscreen window so AppKit-backed controls (buttons, fields, the
	/// segmented picker) and the scroll view render as they do on screen. `ImageRenderer` draws
	/// this pane blank on macOS. The window is never shown and is drawn as the key window, so the
	/// prominent button keeps its colour.
	static func render<V: View>(_ view: V, size: CGSize, name: String, scheme: ColorScheme = .light) throws -> URL {
		let root = view.frame(width: size.width, height: size.height)
			.background(Color(nsColor: .windowBackgroundColor))
			.environment(\.colorScheme, scheme)
			.environment(\.controlActiveState, .key)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
		window.contentView = hosting
		hosting.layoutSubtreeIfNeeded()
		RunLoop.current.run(until: Date().addingTimeInterval(0.3))
		hosting.layoutSubtreeIfNeeded()
		let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
		hosting.cacheDisplay(in: hosting.bounds, to: rep)
		let data = try #require(rep.representation(using: .png, properties: [:]))
		let url = directory.appendingPathComponent(name)
		try data.write(to: url)
		return url
	}

	@Test func accountPaneSignedInWithDevices() async throws {
		let helper = FakeHelperAccountLink()
		helper.registered = true
		helper.pending = [AccountFixtures.pendingPhone]
		let devices = [
			try AccountFixtures.device(helper.macID, name: "Studio Mac", platform: .macos),
			try AccountFixtures.device(AccountFixtures.pendingPhone.deviceID, name: "Uzi's iPhone", platform: .ios),
			try AccountFixtures.device("dev_dddddddddddddddddddddddd", name: "Old iPhone", platform: .ios, revoked: true),
		]
		let signIn = FakeAccountSigningIn(
			.oidc(
				OIDCTokens(
					issuer: URL(string: "https://clerk.whispera.mansurov.dev")!, clientID: "c", accessToken: "a",
					idToken: "i", subject: "uzi@example.com")))
		let model = AccountSettingsModel(
			defaults: AccountFixtures.defaults(), signIn: signIn, directory: FakeAccountDirectory(devices),
			helper: helper, hostedClientID: { "c" })
		await model.load()
		let confirmations = ApproveConfirmModel(helper: helper, authenticator: FakeAuthenticator(result: .success))
		await confirmations.refresh()
		#expect(model.devices.count == 3)

		let view = AccountSettingsView(model: model, confirmations: confirmations, live: false)
		let url = try Self.render(view, size: CGSize(width: 680, height: 760), name: "mac-settings-account.png")
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test func confirmCard() throws {
		let card = ApproveConfirmCard(item: AccountFixtures.pendingPhone, isConfirming: false, confirm: {}, notNow: {})
			.padding(20)
		let url = try Self.render(card, size: CGSize(width: 560, height: 190), name: "mac-confirm-card.png")
		#expect(FileManager.default.fileExists(atPath: url.path))
	}
}
