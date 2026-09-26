import SwiftUI

/// Extra rows for the Microphone section of Settings.
struct AudioInputSettingsRows: View {
	var body: some View {
		VoiceActivitySettingsRows()
	}
}

struct VoiceActivitySettingsRows: View {
	@AppStorage(VoiceActivitySettings.enabledKey) private var vadEnabled = VoiceActivitySettings
		.defaultEnabled
	@AppStorage(VoiceActivitySettings.sensitivityKey) private var vadSensitivity = VoiceActivitySettings
		.defaultSensitivity.rawValue

	var body: some View {
		SettingRow(
			"Skip Silence",
			description: "Trim silence from dictation clips and skip clips with no speech"
		) {
			Toggle("", isOn: $vadEnabled)
		}

		if vadEnabled {
			SettingRow(
				"Speech Sensitivity",
				description: "Raise it if quiet speech gets skipped; lower it in noisy rooms"
			) {
				Picker("", selection: $vadSensitivity) {
					ForEach(VADSensitivity.allCases) { level in
						Text(level.displayName).tag(level.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 120)
			}
		}
	}
}
