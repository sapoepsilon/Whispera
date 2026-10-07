// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import LinkHelperXPC
import SwiftUI
import WhisperaLink

/// Settings > Account: sign in to a Whispera account so this Mac and your iPhone find each other
/// without a pairing code, see and revoke the account's devices, and confirm a new iPhone before
/// it may approve secrets here.
struct AccountSettingsView: View {
	@State private var model: AccountSettingsModel
	@State private var confirmations: ApproveConfirmModel
	/// Off for snapshots and previews: no polling, no network.
	private let live: Bool

	init(
		model: AccountSettingsModel = .shared, confirmations: ApproveConfirmModel = .shared, live: Bool = true
	) {
		_model = State(initialValue: model)
		_confirmations = State(initialValue: confirmations)
		self.live = live
	}

	var body: some View {
		Form {
			if !confirmations.visible.isEmpty {
				confirmSection
			}
			Section {
				if model.isSignedIn {
					signedIn
				} else {
					signedOut
				}
			} header: {
				Text("Account")
			} footer: {
				Group {
					if model.isSignedIn {
						Text(verbatim: model.helperSummary)
					} else {
						Text("Sign in on this Mac and on your iPhone with the same account, and they find each other — no pairing code.")
					}
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			if model.isSignedIn {
				Section {
					devices
				} header: {
					Text("Devices")
				}
			}
			serverSection
		}
		.formStyle(.grouped)
		.task {
			guard live else { return }
			await model.load()
			while !Task.isCancelled {
				await confirmations.refresh()
				try? await Task.sleep(nanoseconds: 5_000_000_000)
			}
		}
		.modifier(AccountAlerts(model: model, confirmations: confirmations))
	}

	private var confirmSection: some View {
		Section {
			ForEach(confirmations.visible) { item in
				ApproveConfirmCard(
					item: item, isConfirming: confirmations.confirmingID == item.deviceID,
					confirm: { Task { await confirmations.confirm(item) } },
					notNow: { confirmations.notNow(item) })
			}
		} header: {
			Text("Confirm iPhones")
		}
	}

	private var serverSection: some View {
		Section {
			TextField(
				"Backend URL", text: $model.backendURL, prompt: Text(verbatim: AccountSettingsKeys.defaultBackendURL)
			)
			.autocorrectionDisabled()
			.disabled(model.isSignedIn)
		} header: {
			Text("Server")
		} footer: {
			Text("Where your account's devices meet. Self-hosters point this at their own server.")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}

	// MARK: Signed in

	private var signedIn: some View {
		HStack {
			Image(systemName: "person.crop.circle.fill")
				.font(.title2)
				.foregroundColor(.accentColor)
			VStack(alignment: .leading, spacing: 2) {
				Text("Signed in as")
					.font(.caption)
					.foregroundColor(.secondary)
				Text(verbatim: model.accountLabel)
					.font(.headline)
			}
			Spacer()
			Button("Sign Out") { Task { await model.signOut() } }
				.disabled(model.isWorking)
		}
	}

	// MARK: Signed out

	@ViewBuilder
	private var signedOut: some View {
		Picker("Sign in with", selection: $model.provider) {
			ForEach(AccountProvider.allCases) { provider in
				Text(verbatim: provider.title).tag(provider)
			}
		}
		.pickerStyle(.segmented)

		switch model.provider {
		case .hosted:
			if !model.hostedSignInAvailable {
				Text("Hosted sign-in isn't set up in this build. Use a custom issuer or a server token.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		case .custom:
			TextField(text: $model.customIssuer, prompt: Text("Issuer (https://auth.example.com)")) {
				Text("Issuer (https://auth.example.com)")
			}
			.labelsHidden()
			.autocorrectionDisabled()
			TextField("Client ID", text: $model.customClientID)
				.autocorrectionDisabled()
			Text("Register whispera-mac://auth/callback as a redirect URI with your provider.")
				.font(.caption)
				.foregroundColor(.secondary)
		case .serverToken:
			SecureField("Server token", text: $model.serverToken)
			Text("A token your self-hosted server accepts. It is kept in the Keychain.")
				.font(.caption)
				.foregroundColor(.secondary)
		}

		HStack {
			Spacer()
			if model.isWorking {
				ProgressView().controlSize(.small)
			}
			Button {
				Task { await model.signInTapped() }
			} label: {
				Label(
					model.provider == .serverToken ? LocalizedStringKey("Use Server Token") : LocalizedStringKey("Sign In"),
					systemImage: "person.crop.circle")
			}
			.buttonStyle(.borderedProminent)
			.disabled(!model.canSignIn)
		}
	}

	// MARK: Devices

	@ViewBuilder
	private var devices: some View {
		if model.devices.isEmpty {
			Text("No devices yet. Sign in on your iPhone with the same account.")
				.font(.caption)
				.foregroundColor(.secondary)
		} else {
			ForEach(model.devices) { row in
				AccountDeviceRowView(
					row: row, revoke: { Task { await model.revoke(row) } }, disabled: model.isWorking)
			}
		}
	}
}

struct AccountDeviceRowView: View {
	let row: AccountDeviceRow
	let revoke: () -> Void
	let disabled: Bool

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: row.systemImage)
				.font(.title3)
				.frame(width: 24)
				.foregroundColor(row.isRevoked ? .secondary : .primary)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(verbatim: row.name)
						.font(.body)
						.strikethrough(row.isRevoked)
					if row.isThisMac {
						Text("This Mac")
							.font(.caption2)
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(Capsule().fill(Color.accentColor.opacity(0.15)))
					}
				}
				HStack(spacing: 6) {
					Text(verbatim: row.platformName)
					Text(verbatim: "·")
					Text(verbatim: row.fingerprint)
						.font(.caption.monospaced())
					if !row.isRevoked, let push = row.pushTextLabel {
						Text(verbatim: "·")
						Text(verbatim: push)
					}
					if !row.isRevoked, row.isLastUsed {
						Text(verbatim: "·")
						Text("Last used")
					}
				}
				.font(.caption)
				.foregroundColor(.secondary)
				if row.isUntrusted {
					Text("Its keys don't match what the server lists. Don't trust this device.")
						.font(.caption)
						.foregroundColor(.red)
				}
			}
			Spacer()
			if row.isRevoked {
				Text("Revoked")
					.font(.caption)
					.foregroundColor(.secondary)
			} else if !row.isThisMac {
				// Sign out covers this Mac.
				Button("Revoke", role: .destructive, action: revoke)
					.disabled(disabled)
			}
		}
		.padding(.vertical, 2)
	}
}

/// "<iPhone> wants to approve secrets on this Mac": shown until the owner compares the safety
/// number with the iPhone's screen and confirms with Touch ID. Until then the iPhone gets
/// nothing from this Mac.
struct ApproveConfirmCard: View {
	let item: PendingApproveConfirmation
	let isConfirming: Bool
	let confirm: () -> Void
	let notNow: () -> Void

	/// The warning for a device whose keys changed, nil otherwise.
	static func keyChangeWarning(for item: PendingApproveConfirmation) -> String? {
		item.keyChanged
			? String(localized: "This device's keys changed. If you didn't reinstall Whispera on it, don't confirm.")
			: nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: item.keyChanged ? "exclamationmark.triangle.fill" : "iphone.badge.exclamationmark")
					.font(.title)
					.foregroundColor(item.keyChanged ? .red : .orange)
				VStack(alignment: .leading, spacing: 4) {
					Text(String(format: String(localized: "%@ wants to approve secrets on this Mac"), item.name))
						.font(.headline)
					Text("It joined your account. It can't reach this Mac until you confirm it here.")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			if let warning = Self.keyChangeWarning(for: item) {
				Label(warning, systemImage: "exclamationmark.triangle")
					.font(.callout.weight(.semibold))
					.foregroundColor(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			VStack(alignment: .leading, spacing: 4) {
				Text("Safety number — must match the one on your iPhone")
					.font(.caption)
					.foregroundColor(.secondary)
				if let number = item.safetyNumber {
					Text(verbatim: number)
						.font(.system(size: 28, weight: .semibold, design: .monospaced))
						.textSelection(.enabled)
						.accessibilityIdentifier("approve-confirm-safety-number")
				} else {
					Text("Not available yet")
						.font(.callout)
						.foregroundColor(.secondary)
				}
				HStack(spacing: 6) {
					Text("Fingerprint")
					Text(verbatim: item.fingerprint)
						.font(.caption.monospaced())
				}
				.font(.caption)
				.foregroundColor(.secondary)
			}
			HStack {
				Spacer()
				if item.keyChanged {
					Button("Not Now", action: notNow)
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.cancelAction)
						.disabled(isConfirming)
					confirmButton
						.buttonStyle(.bordered)
				} else {
					Button("Not Now", action: notNow)
						.disabled(isConfirming)
					confirmButton
						.buttonStyle(.borderedProminent)
				}
			}
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 10).fill((item.keyChanged ? Color.red : Color.orange).opacity(0.08))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10).stroke((item.keyChanged ? Color.red : Color.orange).opacity(0.35)))
	}

	private var confirmButton: some View {
		Button(action: confirm) {
			Label("Numbers Match — Confirm with Touch ID", systemImage: "touchid")
		}
		.disabled(isConfirming || item.safetyNumber == nil)
	}
}

private struct AccountAlerts: ViewModifier {
	@Bindable var model: AccountSettingsModel
	@Bindable var confirmations: ApproveConfirmModel

	func body(content: Content) -> some View {
		content
			.alert(
				"Account",
				isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } }),
				presenting: model.lastError
			) { _ in
				Button("OK", role: .cancel) {}
			} message: { message in
				Text(message)
			}
			.alert(
				"Couldn't confirm the iPhone",
				isPresented: Binding(
					get: { confirmations.lastError != nil }, set: { if !$0 { confirmations.lastError = nil } }),
				presenting: confirmations.lastError
			) { _ in
				Button("OK", role: .cancel) {}
			} message: { message in
				Text(message)
			}
	}
}
