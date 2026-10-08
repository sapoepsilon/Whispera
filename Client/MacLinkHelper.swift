// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import LinkHelperXPC
import WhisperaLink
import ServiceManagement
import SwiftUI

/// Whispera's side of the Mac link: registers the login-item helper that keeps serving paired
/// phones while Whispera is quit, and asks it for its status over its Mach service.
@MainActor
final class MacLinkHelper: ObservableObject {
	static let shared = MacLinkHelper()
	static let enabledKey = "whisperaLinkHelperEnabled"

	@Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
	@Published private(set) var helperStatus: HelperStatus?
	@Published var lastError: String?

	private let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

	/// The embedded helper's bundle id: `com.macwhisper.app.LinkHelper` in release builds,
	/// `com.macwhisper.app.debug.LinkHelper` in debug ones. launchd names its Mach service the same.
	nonisolated static var helperBundleIdentifier: String {
		let plist = Bundle.main.bundleURL.appendingPathComponent(
			"Contents/Library/LoginItems/WhisperaLinkHelper.app/Contents/Info.plist")
		let info = NSDictionary(contentsOf: plist)
		return info?["CFBundleIdentifier"] as? String ?? LinkHelperXPC.helperBundleIdentifier
	}

	private var service: SMAppService { SMAppService.loginItem(identifier: Self.helperBundleIdentifier) }

	/// At launch: keep the registration in step with the setting, so a reinstall or an update that
	/// moved the app re-registers the helper it now carries, and a switched-off link stays off.
	func applyAtLaunch() {
		serviceStatus = service.status
		if isEnabled, serviceStatus != .enabled {
			setEnabled(true)
		} else if !isEnabled, serviceStatus == .enabled {
			setEnabled(false)
		}
		guard isEnabled else { return }
		ApprovalCardCenter.shared.start()
		Task {
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			await refresh()
			if let status = helperStatus {
				AppLogger.shared.general.info(
					"Mac link helper answering: pid \(status.pid) port \(status.port) devices \(status.devices) speech \(status.sttEngine ?? status.sttMode ?? status.stt)"
				)
			} else {
				AppLogger.shared.general.error("Mac link helper did not answer over XPC (status \(self.serviceStatus.rawValue))")
			}
			await syncSpeechServerKey()
			await syncRecipeServerKey()
			observeSpeechServerAddress()
			// A signed-in Mac re-hands the bearer, so a helper that lost its state joins again;
			// one that is already on the account does nothing.
			await AccountSettingsModel.shared.handOffAtLaunch()
			await ApproveConfirmModel.shared.refresh()
		}
	}

	func setEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: Self.enabledKey)
		do {
			if enabled {
				try service.register()
				AppLogger.shared.general.info("Mac link helper registered")
				ApprovalCardCenter.shared.start()
				Task {
					try? await Task.sleep(nanoseconds: 3_000_000_000)
					await syncSpeechServerKey()
					await syncRecipeServerKey()
					observeSpeechServerAddress()
				}
			} else {
				try service.unregister()
				ApprovalCardCenter.shared.stop()
				helperStatus = nil
				AppLogger.shared.general.info("Mac link helper unregistered")
			}
			lastError = nil
		} catch {
			lastError = error.localizedDescription
			AppLogger.shared.general.error("Mac link helper registration failed: \(error.localizedDescription)")
		}
		serviceStatus = service.status
	}

	private var speechAddressObserver: NSObjectProtocol?
	private var handedSpeechAddress: String?

	/// Hands the helper the speech server's API key, bound to the server's address, so a paired
	/// phone transcribing with this Mac's engine reaches that server while Whispera is quit. The
	/// helper reads the selected engine, address and model from Whispera's settings itself; only
	/// the key, which lives in Whispera's Keychain, has to be handed over. `{}` clears it.
	func syncSpeechServerKey() async {
		guard isEnabled else { return }
		let entry = WhisperaSettings.speechServer
		var request: [String: String] = [:]
		if let url = entry.url, let key = entry.keyProvider(), !key.isEmpty {
			request = ["base_url": url.absoluteString, "key": key]
		}
		handedSpeechAddress = entry.url?.absoluteString ?? ""
		let body = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
		let reply = await Self.call { $0.setSpeechServerKey(body, reply: $1) }
		let ok = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool
		if ok == true {
			AppLogger.shared.general.info(
				"Mac link helper has the speech server key: \(request.isEmpty ? "none" : "set")")
		} else {
			AppLogger.shared.general.error("Mac link helper did not take the speech server key")
		}
	}

	private var handedRecipeAddress: String?
	func syncRecipeServerKey() async {
		guard isEnabled else { return }
		let entry = WhisperaSettings.llmServer
		var request: [String: String] = [:]
		if let url = entry.url, let key = entry.keyProvider(), !key.isEmpty {
			request = ["base_url": url.absoluteString, "key": key]
		}
		let body = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
		let reply = await Self.call { $0.setRecipeServerKey(body, reply: $1) }
		if reply.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["ok"] as? Bool == true {
			handedRecipeAddress = entry.url?.absoluteString ?? ""
		} else { AppLogger.shared.general.error("Mac link helper did not take the recipe server key") }
	}

	/// A key is bound to the address it was handed for, so a new speech server address hands it again.
	private func observeSpeechServerAddress() {
		guard speechAddressObserver == nil else { return }
		speechAddressObserver = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self, self.isEnabled else { return }
				let address = WhisperaSettings.speechServer.url?.absoluteString ?? ""
				if address != self.handedSpeechAddress { await self.syncSpeechServerKey() }
				if (WhisperaSettings.llmServer.url?.absoluteString ?? "") != self.handedRecipeAddress { await self.syncRecipeServerKey() }
			}
		}
	}

	func openLoginItemsSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}

	/// Asks the running helper for its status; nil when it does not answer within two seconds.
	func refresh() async {
		serviceStatus = service.status
		guard serviceStatus == .enabled else {
			helperStatus = nil
			return
		}
		helperStatus = await Self.fetchStatus(machServiceName: Self.helperBundleIdentifier)
	}

	nonisolated static func fetchStatus(machServiceName: String, timeout: TimeInterval = 2) async -> HelperStatus? {
		await call(machServiceName: machServiceName, timeout: timeout) { $0.status(reply: $1) }
			.flatMap(LinkHelperXPC.decodeStatus)
	}

	/// One request to the running helper; nil when it does not answer within `timeout`.
	nonisolated static func call(
		machServiceName: String? = nil, timeout: TimeInterval = 5,
		_ send: (LinkHelperXPCProtocol, @escaping (Data) -> Void) -> Void
	) async -> Data? {
		let name = machServiceName ?? helperBundleIdentifier
		let connection = NSXPCConnection(machServiceName: name, options: [])
		connection.remoteObjectInterface = NSXPCInterface(with: LinkHelperXPCProtocol.self)
		if isDeveloperIDSigned { connection.setCodeSigningRequirement(LinkHelperXPC.helperRequirement) }
		connection.resume()
		defer { connection.invalidate() }
		return await withCheckedContinuation { continuation in
			let once = OnceBox(continuation)
			let proxy =
				connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? LinkHelperXPCProtocol
			guard let proxy else { return once.resume(nil) }
			send(proxy) { data in once.resume(data) }
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
		}
	}

	/// Whether this app carries the Developer ID signature, which is when the helper's own
	/// signature can be required of it.
	nonisolated static var isDeveloperIDSigned: Bool {
		var code: SecCode?
		var requirement: SecRequirement?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString(LinkHelperXPC.clientRequirement as CFString, [], &requirement)
				== errSecSuccess,
			let requirement
		else { return false }
		return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
	}

	private final class OnceBox: @unchecked Sendable {
		private let lock = NSLock()
		private var continuation: CheckedContinuation<Data?, Never>?

		init(_ continuation: CheckedContinuation<Data?, Never>) {
			self.continuation = continuation
		}

		func resume(_ value: Data?) {
			lock.lock()
			let pending = continuation
			continuation = nil
			lock.unlock()
			pending?.resume(returning: value)
		}
	}
}

/// Settings ▸ Servers ▸ Mac Link: one switch and what the helper reports.
struct MacLinkSettingsSection: View {
	@ObservedObject private var helper = MacLinkHelper.shared
	@AppStorage(MacLinkHelper.enabledKey) private var enabled = false
	@State private var confirmations = ApproveConfirmModel.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Toggle(
				"Keep the Mac link running when Whispera is quit",
				isOn: Binding(get: { enabled }, set: { helper.setEnabled($0) })
			)
			Text(
				"Your paired iPhone can reach your agents, approve secret requests and transcribe with this Mac's model."
			)
			.font(.caption)
			.foregroundColor(.secondary)
			if helper.serviceStatus == .requiresApproval {
				HStack {
					Text("Allow Whispera Link in Login Items to finish turning it on.")
						.font(.caption)
					Button("Open Login Items") { helper.openLoginItemsSettings() }
				}
			}
			if let status = helper.helperStatus {
				Text(
					String(
						format: String(
							localized: "Running on port %lld · %lld paired devices · speech: %@"),
						Int64(status.port), Int64(status.devices),
						status.sttEngine ?? status.sttMode ?? status.stt)
				)
				.font(.caption.monospacedDigit())
				.foregroundColor(.secondary)
				// What a phone pairing by typed address and code shows before it sends the code.
				Text(
					String(
						format: String(localized: "Mac fingerprint: %@"), LinkCrypto.displayFingerprint(status.daemonFP))
				)
				.font(.caption.monospaced())
				.foregroundColor(.secondary)
				.textSelection(.enabled)
				if !confirmations.visible.isEmpty {
					Text("An iPhone is waiting for you to confirm it in Settings > Account.")
						.font(.caption)
						.foregroundColor(.orange)
				}
			} else if enabled && helper.serviceStatus == .enabled {
				Text("The Mac link is starting…")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			if enabled && helper.serviceStatus == .enabled {
				Divider()
				MacApproverSettingsRow()
			}
		}
		.task {
			await helper.refresh()
			await confirmations.refresh()
		}
		.alert(
			"Couldn't change the Mac link",
			isPresented: Binding(get: { helper.lastError != nil }, set: { if !$0 { helper.lastError = nil } }),
			presenting: helper.lastError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}
}
