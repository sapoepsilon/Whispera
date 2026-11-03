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
	@State private var links: MacLinkModel
	/// Off for snapshots and previews: no polling, no network.
	private let live: Bool

	init(
		model: AccountSettingsModel = .shared, confirmations: ApproveConfirmModel = .shared,
		links: MacLinkModel = .shared, live: Bool = true
	) {
		_model = State(initialValue: model)
		_confirmations = State(initialValue: confirmations)
		_links = State(initialValue: links)
		self.live = live
	}

	var body: some View {
		Form {
			if !links.visible.isEmpty {
				linkSection
			}
			if !links.linked.isEmpty {
				linkedSection
			}
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
				await links.refresh()
				try? await Task.sleep(nanoseconds: 5_000_000_000)
			}
		}
		.modifier(AccountAlerts(model: model, confirmations: confirmations))
		.alert(
			"Couldn't link the Mac",
			isPresented: Binding(get: { links.lastError != nil }, set: { if !$0 { links.lastError = nil } }),
			presenting: links.lastError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private var linkedSection: some View {
		Section {
			ForEach(links.linked) { item in
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(verbatim: item.tailnetName).font(.body.weight(.medium))
						Text(verbatim: item.keyChanged ? item.name : "\(item.name) · \(item.linkFingerprint)")
							.font(.caption.monospaced())
							.foregroundColor(.secondary)
						if item.keyChanged {
							Text("It now answers from another tailnet node. Relink it if you reinstalled or re-logged Tailscale there.")
								.font(.caption)
								.foregroundColor(.orange)
						}
					}
					Spacer()
					Button("Relink…") { Task { await links.relink(item) } }
						.disabled(links.decidingID != nil)
						.accessibilityIdentifier("mac-link-relink")
					if !item.keyChanged {
						Button("Unlink…", role: .destructive) { Task { await links.decline(item) } }
							.disabled(links.decidingID != nil)
							.accessibilityIdentifier("mac-link-unlink")
					}
				}
			}
		} header: {
			Text("Linked Macs")
		} footer: {
			Text("A linked Mac's word counts here: the iPhones it confirmed can use this Mac. Unlink one you no longer trust.")
		}
	}

	private var linkSection: some View {
		Section {
			ForEach(links.visible) { item in
				MacLinkCard(
					item: item, isDeciding: links.decidingID == item.deviceID,
					link: { Task { await links.link(item) } },
					decline: { Task { await links.decline(item) } },
					notNow: { links.notNow(item) })
			}
		} header: {
			Text("Link Macs")
		}
	}

	private var confirmSection: some View {
		Section {
			ForEach(confirmations.visible) { item in
				if item.vouchedBy != nil {
					VouchedConfirmCard(
						item: item, isConfirming: confirmations.confirmingID == item.deviceID,
						allow: { Task { await confirmations.confirmVouched(item) } },
						confirmWithNumber: { Task { await confirmations.confirm(item) } },
						notNow: { confirmations.notNow(item) })
				} else {
					ApproveConfirmCard(
						item: item, isConfirming: confirmations.confirmingID == item.deviceID,
						confirm: { Task { await confirmations.confirm(item) } },
						notNow: { confirmations.notNow(item) })
				}
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
				.foregroundColor(.primary)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(verbatim: row.name)
						.font(.body)
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
					if let push = row.pushTextLabel {
						Text(verbatim: "·")
						Text(verbatim: push)
					}
					if row.isLastUsed {
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
			if !row.isThisMac {
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
/// "Allow iPhone X, vouched by Mac Y?": a Mac linked here signed for exactly this iPhone's keys
/// after its safety number was compared there. Only the owner's Touch ID here confirms it; the
/// number stays one click away.
struct VouchedConfirmCard: View {
	let item: PendingApproveConfirmation
	let isConfirming: Bool
	let allow: () -> Void
	let confirmWithNumber: () -> Void
	let notNow: () -> Void
	@State private var showNumber = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "checkmark.seal")
					.font(.title)
					.foregroundColor(.accentColor)
				VStack(alignment: .leading, spacing: 4) {
					Text(String(format: String(localized: "Allow %@?"), item.name))
						.font(.headline)
					Text(
						String(
							format: String(localized: "%@ says you compared this iPhone's safety number there. Allow it here only if you did; otherwise compare the number. It can't reach this Mac until you allow it."),
							item.vouchedByName ?? String(localized: "Another Mac of yours"))
					)
						.font(.caption)
						.foregroundColor(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			if let fingerprint = item.linkFingerprint {
				HStack(spacing: 6) {
					Text("Fingerprint")
					Text(verbatim: fingerprint).font(.caption.monospaced())
				}
				.font(.caption)
				.foregroundColor(.secondary)
			}
			if showNumber, let number = item.safetyNumber {
				Text(verbatim: number)
					.font(.system(size: 24, weight: .semibold, design: .monospaced))
					.textSelection(.enabled)
			}
			HStack {
				Button(showNumber ? "Hide Number" : "Compare Number Instead") { showNumber.toggle() }
					.buttonStyle(.link)
				Spacer()
				Button("Not Now", action: notNow)
					.disabled(isConfirming)
				if showNumber {
					Button(action: confirmWithNumber) { Label("Numbers Match — Confirm", systemImage: "touchid") }
						.disabled(isConfirming || item.safetyNumber == nil)
				}
				Button(action: allow) { Label("Allow with Touch ID", systemImage: "touchid") }
					.buttonStyle(.borderedProminent)
					.disabled(isConfirming)
					.accessibilityIdentifier("approve-confirm-vouched")
			}
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))
	}
}

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

	/// The warning for a Mac that saw safety-number attempts end without a number, nil otherwise.
	static func unfinishedWarning(for item: PendingApproveConfirmation) -> String? {
		item.sasUnfinished > 0
			? String(localized: "A pairing attempt didn't finish. If you didn't start it, don't confirm.")
			: nil
	}

	/// What the card says while it has no number to compare.
	static func missingNumberText(for item: PendingApproveConfirmation) -> String {
		switch item.sasStatus {
		case "update_required":
			return String(localized: "Update Whispera on the iPhone, then open it. This version of the iPhone app can't show a safety number this Mac accepts.")
		case "failed":
			return String(localized: "The iPhone's keys didn't match what it committed to. Open Whispera on the iPhone to start over, and don't confirm if this repeats.")
		default:
			return String(localized: "Waiting for the iPhone. Open Whispera on it to show the number.")
		}
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
			if let warning = Self.unfinishedWarning(for: item) {
				Label(warning, systemImage: "exclamationmark.triangle")
					.font(.callout.weight(.semibold))
					.foregroundColor(.orange)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityIdentifier("approve-confirm-sas-unfinished")
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
					Text(Self.missingNumberText(for: item))
						.font(.callout)
						.foregroundColor(item.sasStatus == "waiting" || item.sasStatus == nil ? .secondary : .orange)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityIdentifier("approve-confirm-sas-status")
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

/// "Link MacBook Pro (5)?": another Mac of the account, on the owner's tailnet. One Touch ID,
/// no number to compare. The tailnet name is what Tailscale says about the connection; if it
/// isn't a Mac of yours, don't link it.
struct MacLinkCard: View {
	let item: PendingMacLink
	let isDeciding: Bool
	let link: () -> Void
	let decline: () -> Void
	let notNow: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: item.keyChanged ? "exclamationmark.triangle.fill" : "laptopcomputer.and.arrow.down")
					.font(.title)
					.foregroundColor(item.keyChanged ? .red : .accentColor)
				VStack(alignment: .leading, spacing: 4) {
					Text(String(format: String(localized: "Link %@?"), item.tailnetName))
						.font(.headline)
					Text(
						String(
							format: String(localized: "A helper answered from %@ on your tailnet and calls itself \u{201C}%@\u{201D} on your account. Link it only if %@ is one of your Macs."),
							item.tailnetName, item.name, item.tailnetName)
					)
					.font(.caption)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					if let firstSeen = item.firstSeen {
						Text(
							String(
								format: String(localized: "First seen %@"),
								Date(timeIntervalSince1970: TimeInterval(firstSeen)).formatted(date: .abbreviated, time: .shortened))
						)
						.font(.caption)
						.foregroundColor(.secondary)
					}
					if item.vouchedBy != nil {
						Text("A Mac you linked says it linked this one too. That's its claim, not proof: check the name.")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
			if item.keyChanged {
				Label("This Mac's keys changed since you linked it. If you didn't reinstall Whispera on it, don't link it.",
					systemImage: "exclamationmark.triangle")
					.font(.callout.weight(.semibold))
					.foregroundColor(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Text(verbatim: item.linkFingerprint)
					.font(.caption.monospaced())
					.foregroundColor(.secondary)
				Spacer()
				Button("Not Now", action: notNow)
					.disabled(isDeciding)
				Button("Don't Link", role: .destructive, action: decline)
					.disabled(isDeciding)
				Button(action: link) {
					Label("Link with Touch ID", systemImage: "touchid")
				}
				.buttonStyle(.borderedProminent)
				.disabled(isDeciding)
				.accessibilityIdentifier("mac-link-approve")
			}
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))
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
