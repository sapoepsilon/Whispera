import SwiftUI

struct RecordingControlSettingsView: View {
	@AppStorage(RecordingControlSettings.Key.cancelShortcutEnabled) private var cancelShortcutEnabled =
		true

	var body: some View {
		SettingsSection("Recording Control") {
			SettingRow(
				"Cancel with Escape",
				description: "Press Esc while recording or transcribing to discard it without pasting"
			) {
				Toggle("", isOn: $cancelShortcutEnabled)
					.accessibilityIdentifier("cancelShortcutToggle")
			}
		}
	}
}
