import SwiftUI

struct ModelMemorySettingsView: View {
	@AppStorage(RecordingControlSettings.Key.modelUnloadTimeout) private var unloadTimeoutRaw =
		ModelUnloadTimeout.never.rawValue
	@State private var whisperKit = WhisperKitTranscriber.shared
	@State private var isWorking = false

	var body: some View {
		SettingRow(
			"Unload Model When Idle",
			description:
				"Free the model's memory after a period without dictation. It reloads on the next shortcut press."
		) {
			Picker("Unload model when idle", selection: $unloadTimeoutRaw) {
				ForEach(ModelUnloadTimeout.allCases) { timeout in
					Text(timeout.displayName).tag(timeout.rawValue)
				}
			}
			.labelsHidden()
			.frame(width: 180)
			.accessibilityIdentifier("modelUnloadTimeoutPicker")
		}

		SettingRow(
			"Model Memory",
			description: whisperKit.isIdleUnloaded
				? "Model is unloaded and will load on next use"
				: "Release the loaded model now"
		) {
			if whisperKit.isIdleUnloaded {
				Button("Load Now") {
					isWorking = true
					Task {
						try? await whisperKit.waitForReadyForTranscription()
						isWorking = false
					}
				}
				.disabled(isWorking || whisperKit.isModelLoading)
				.accessibilityIdentifier("loadModelNowButton")
			} else {
				Button("Unload Now") {
					isWorking = true
					Task {
						await whisperKit.unloadModel()
						isWorking = false
					}
				}
				.disabled(isWorking || !whisperKit.canUnloadModel)
				.accessibilityIdentifier("unloadModelNowButton")
			}
		}
	}
}
