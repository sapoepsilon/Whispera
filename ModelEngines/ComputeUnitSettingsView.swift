import SwiftUI

struct ComputeUnitSettingsView: View {
	@State var whisperKit: WhisperKitTranscriber
	@State private var selection: ComputeUnitPreference = ComputeUnitPreference.load()
	@State private var isApplying = false
	@State private var applyError: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			SettingRow(
				"Accelerator",
				description: "Which hardware runs the speech model. Changing it reloads the model."
			) {
				HStack(spacing: 8) {
					if isApplying {
						ProgressView()
							.scaleEffect(0.5)
					}
					Picker("Accelerator", selection: $selection) {
						ForEach(ComputeUnitPreference.allCases) { preference in
							Text(preference.displayName).tag(preference)
						}
					}
					.labelsHidden()
					.frame(width: 160)
					.disabled(isApplying || whisperKit.isModelLoading || whisperKit.isDownloadingModel)
					.accessibilityIdentifier("computeUnitPicker")
				}
			}

			Text(selection.summary)
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.onChange(of: selection) { _, newValue in
			apply(newValue)
		}
		.alert(
			"Couldn't switch accelerator",
			isPresented: Binding(
				get: { applyError != nil },
				set: { if !$0 { applyError = nil } }
			),
			presenting: applyError
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { message in
			Text(message)
		}
	}

	private func apply(_ preference: ComputeUnitPreference) {
		isApplying = true
		Task { @MainActor in
			defer { isApplying = false }
			do {
				try await whisperKit.applyComputeUnitPreference(preference)
			} catch {
				AppLogger.shared.transcriber.error("Failed to apply compute units: \(error)")
				applyError = error.localizedDescription
			}
		}
	}
}
