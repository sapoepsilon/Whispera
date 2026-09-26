import SwiftUI

struct ParakeetSettingsNote: View {
	let modelID: String?

	var body: some View {
		if let modelID, let model = ParakeetModel(rawValue: modelID) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Parakeet runs on CoreML through FluidAudio (Neural Engine by default).")
					.font(.caption)
				Text(model.languageSummary)
					.font(.caption)
					.foregroundColor(.secondary)
				Text(
					"Translation and Live Transcription Mode need a Whisper model; dictation transcribes when you stop recording."
				)
				.font(.caption)
				.foregroundColor(.secondary)
			}
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityIdentifier("parakeetSettingsNote")
		}
	}
}
