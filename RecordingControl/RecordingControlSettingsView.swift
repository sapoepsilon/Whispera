import SwiftUI

struct RecordingControlSettingsView: View {
	@AppStorage(RecordingControlSettings.Key.activationMode) private var activationModeRaw =
		ActivationMode.toggle.rawValue
	@AppStorage(RecordingControlSettings.Key.holdThresholdMs) private var holdThresholdMs =
		RecordingControlSettings.defaultHoldThresholdMs
	@AppStorage(RecordingControlSettings.Key.cancelShortcutEnabled) private var cancelShortcutEnabled =
		true
	@AppStorage(RecordingControlSettings.Key.extraRecordingBufferMs) private var extraRecordingBufferMs = 0

	private var activationMode: ActivationMode {
		ActivationMode(rawValue: activationModeRaw) ?? .toggle
	}

	var body: some View {
		SettingsSection("Recording Control") {
			SettingRow("Shortcut Activation", description: activationMode.summary) {
				Picker("Shortcut activation", selection: $activationModeRaw) {
					ForEach(ActivationMode.allCases) { mode in
						Text(mode.displayName).tag(mode.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 180)
				.accessibilityIdentifier("activationModePicker")
			}

			if activationMode == .holdOrToggle {
				SettingRow(
					"Hold Threshold",
					description: "Presses longer than this record until you let go"
				) {
					Stepper(
						"\(holdThresholdMs) ms",
						value: $holdThresholdMs,
						in: RecordingControlSettings.holdThresholdRange,
						step: 50
					)
					.frame(width: 180, alignment: .trailing)
					.accessibilityIdentifier("holdThresholdStepper")
				}
			}

			SettingRow(
				"Extra Recording After Stop",
				description: "Keep capturing briefly after you stop so trailing words are not cut off"
			) {
				Stepper(
					extraRecordingBufferMs == 0 ? "Off" : "\(extraRecordingBufferMs) ms",
					value: $extraRecordingBufferMs,
					in: RecordingControlSettings.extraRecordingBufferRange,
					step: 50
				)
				.frame(width: 180, alignment: .trailing)
				.accessibilityIdentifier("extraRecordingBufferStepper")
			}

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
