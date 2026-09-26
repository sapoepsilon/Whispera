import SwiftUI

struct RecordingControlSettingsView: View {
	@AppStorage(RecordingControlSettings.Key.activationMode) private var activationModeRaw =
		ActivationMode.toggle.rawValue
	@AppStorage(RecordingControlSettings.Key.holdThresholdMs) private var holdThresholdMs =
		RecordingControlSettings.defaultHoldThresholdMs
	@AppStorage(RecordingControlSettings.Key.cancelShortcutEnabled) private var cancelShortcutEnabled =
		true
	@AppStorage(RecordingControlSettings.Key.extraRecordingBufferMs) private var extraRecordingBufferMs = 0
	@AppStorage(RecordingControlSettings.Key.micStreamPolicy) private var micStreamPolicyRaw =
		MicStreamPolicy.onDemand.rawValue
	@AppStorage(RecordingControlSettings.Key.lazyStreamCloseSeconds) private var lazyStreamCloseSeconds =
		RecordingControlSettings.defaultLazyStreamCloseSeconds
	@AppStorage("enableStreaming") private var liveTranscriptionEnabled = Constants.enableStreamingDefault
	@AppStorage("useStreamingTranscription") private var useStreamingTranscription = true

	private var micStreamPolicy: MicStreamPolicy {
		MicStreamPolicy(rawValue: micStreamPolicyRaw) ?? .onDemand
	}

	private var activationMode: ActivationMode {
		ActivationMode(rawValue: activationModeRaw) ?? .toggle
	}

	private var micStreamPolicyDescription: String {
		if micStreamPolicy != .onDemand && (liveTranscriptionEnabled || !useStreamingTranscription) {
			return "Only applies to streaming transcription with Live Transcription Mode off"
		}
		return micStreamPolicy.summary
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

			SettingRow("Microphone Stream", description: micStreamPolicyDescription) {
				Picker("Microphone stream", selection: $micStreamPolicyRaw) {
					ForEach(MicStreamPolicy.allCases) { policy in
						Text(policy.displayName).tag(policy.rawValue)
					}
				}
				.labelsHidden()
				.frame(width: 180)
				.accessibilityIdentifier("micStreamPolicyPicker")
			}

			if micStreamPolicy == .lazyClose {
				SettingRow("Keep Open For") {
					Picker("Keep open for", selection: $lazyStreamCloseSeconds) {
						ForEach(RecordingControlSettings.lazyStreamCloseOptions, id: \.self) { seconds in
							Text("\(seconds) seconds").tag(seconds)
						}
					}
					.labelsHidden()
					.frame(width: 180)
					.accessibilityIdentifier("lazyStreamClosePicker")
				}
			}

			SettingRow(
				"Cancel Shortcut",
				description: "Press it while recording or transcribing to discard the dictation without pasting. In Live Transcription Mode the text is typed as you speak, so it only stops the stream; what was already typed stays."
			) {
				HStack(spacing: 8) {
					CancelShortcutRecorder()
						.disabled(!cancelShortcutEnabled)
					Toggle("", isOn: $cancelShortcutEnabled)
						.labelsHidden()
						.accessibilityIdentifier("cancelShortcutToggle")
				}
			}
		}
	}
}
