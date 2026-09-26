import SwiftUI

extension SecureInputMonitor {
	var holderDescription: String {
		if let culprit { return String(localized: "\(culprit.name) has turned on Secure Input") }
		return String(localized: "Another app has turned on Secure Input")
	}

	var fallbackDescription: String {
		switch fallbackStatus {
		case .active:
			return String(localized: "Your dictation shortcut still works through a fallback hotkey.")
		case .unavailable:
			return
				String(
					localized:
						"Your dictation shortcut cannot be detected until it ends. Pick a shortcut without the Globe key or close the password field."
				)
		case .disabledByUser:
			return
				String(
					localized:
						"Your dictation shortcut cannot be detected until it ends. Turn on the fallback hotkey in Settings."
				)
		case .inactive:
			return String(localized: "Keyboard shortcuts may not be detected until it ends.")
		}
	}
}

struct SecureInputWarningBanner: View {
	@Bindable var monitor: SecureInputMonitor = .shared

	var body: some View {
		if monitor.isSustained {
			let tint: Color = monitor.showsWarning ? .orange : .blue
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 6) {
					Image(
						systemName: monitor.showsWarning
							? "lock.trianglebadge.exclamationmark" : "lock.fill"
					)
					.foregroundColor(tint)
					Text(monitor.holderDescription)
						.font(.caption)
						.fontWeight(.medium)
						.foregroundColor(tint)
					Spacer()
				}
				Text(monitor.fallbackDescription)
					.font(.caption2)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(8)
			.background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(tint.opacity(0.3), lineWidth: 1)
			)
		}
	}
}

struct SecureInputSettingsRows: View {
	@Bindable var monitor: SecureInputMonitor = .shared
	@AppStorage(SecureInputMonitor.Keys.fallbackEnabled) private var fallbackEnabled = true

	var body: some View {
		SettingRow(
			"Secure Input Fallback",
			description:
				"Password fields and Terminal's Secure Keyboard Entry hide keystrokes from Whispera. This registers the dictation shortcut as a system hotkey while that lasts. Dictations made during Secure Input are pasted as spoken: they skip post-processing and are not saved to history."
		) {
			Toggle("", isOn: $fallbackEnabled)
				.onChange(of: fallbackEnabled) {
					monitor.reconcileFallback()
				}
		}
		.onAppear { monitor.viewDidAppear() }
		.onDisappear { monitor.viewDidDisappear() }

		if monitor.isSustained {
			SecureInputWarningBanner(monitor: monitor)
		}
	}
}
