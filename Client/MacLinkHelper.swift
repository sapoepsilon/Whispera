// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import LinkHelperXPC
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
	static var helperBundleIdentifier: String {
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
		Task {
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			await refresh()
			if let status = helperStatus {
				AppLogger.shared.general.info(
					"Mac link helper answering: pid \(status.pid) port \(status.port) devices \(status.devices) speech \(status.sttMode ?? status.stt)"
				)
			} else {
				AppLogger.shared.general.error("Mac link helper did not answer over XPC (status \(self.serviceStatus.rawValue))")
			}
		}
	}

	func setEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: Self.enabledKey)
		do {
			if enabled {
				try service.register()
				AppLogger.shared.general.info("Mac link helper registered")
			} else {
				try service.unregister()
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
		let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
		connection.remoteObjectInterface = NSXPCInterface(with: LinkHelperXPCProtocol.self)
		if isDeveloperIDSigned { connection.setCodeSigningRequirement(LinkHelperXPC.helperRequirement) }
		connection.resume()
		defer { connection.invalidate() }
		return await withCheckedContinuation { continuation in
			let once = OnceBox(continuation)
			let proxy =
				connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? LinkHelperXPCProtocol
			guard let proxy else { return once.resume(nil) }
			proxy.status { data in once.resume(LinkHelperXPC.decodeStatus(data)) }
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
		private var continuation: CheckedContinuation<HelperStatus?, Never>?

		init(_ continuation: CheckedContinuation<HelperStatus?, Never>) {
			self.continuation = continuation
		}

		func resume(_ value: HelperStatus?) {
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
						Int64(status.port), Int64(status.devices), status.sttMode ?? status.stt)
				)
				.font(.caption.monospacedDigit())
				.foregroundColor(.secondary)
			} else if enabled && helper.serviceStatus == .enabled {
				Text("The Mac link is starting…")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
		.task { await helper.refresh() }
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
