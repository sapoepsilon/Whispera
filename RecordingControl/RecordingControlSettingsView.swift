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

	private var transcriber = WhisperKitTranscriber.shared

	private var captureRoute: CaptureRoute {
		CaptureRoute.resolve(
			liveTranscriptionEnabled: liveTranscriptionEnabled,
			modelSupportsLive: transcriber.supportsLiveTranscription,
			useStreamingTranscription: useStreamingTranscription)
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
				"Microphone Stream", description: micStreamPolicy.settingsDescription(on: captureRoute)
			) {
				HStack(spacing: 6) {
					if micStreamPolicy.inactiveReason(on: captureRoute) != nil {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
							.help(micStreamPolicy.settingsDescription(on: captureRoute))
							.accessibilityLabel("Has no effect in the current recording mode")
					}
					Picker("Microphone stream", selection: $micStreamPolicyRaw) {
						ForEach(MicStreamPolicy.allCases) { policy in
							Text(policy.displayName).tag(policy.rawValue)
						}
					}
					.labelsHidden()
					.frame(width: 180)
					.accessibilityIdentifier("micStreamPolicyPicker")
				}
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
				description:
					"Press it while recording to discard the dictation without pasting. Once transcribing has started it no longer listens, so an Esc meant for another app can't throw the dictation away; use the cancel button on the pill or in the menu bar instead."
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
