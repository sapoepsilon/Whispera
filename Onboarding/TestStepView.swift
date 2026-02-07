import SwiftUI

struct TestStepView: View {
	@Bindable var audioManager: AudioManager
	@Binding var selectedLanguage: String
	@State private var pulseRecord = false

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 8) {
				Text("Try It Out")
					.font(.system(.title2, design: .rounded, weight: .bold))

				Text("Record a short clip to test your setup.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}

			HStack {
				Text("Language")
					.font(.system(.subheadline, design: .rounded))
					.foregroundColor(.secondary)
				Spacer()
				Picker("Language", selection: $selectedLanguage) {
					ForEach(Constants.sortedLanguageNames, id: \.self) { language in
						Text(language.capitalized).tag(language)
					}
				}
				.frame(minWidth: 140)
			}
			.padding(12)
			.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

			VStack(spacing: 16) {
				Button {
					audioManager.toggleRecording()
				} label: {
					ZStack {
						Circle()
							.fill(audioManager.isRecording ? Color.red : Color.blue)
							.frame(width: 64, height: 64)
							.scaleEffect(pulseRecord ? 1.08 : 1.0)
							.shadow(
								color: (audioManager.isRecording ? Color.red : Color.blue)
									.opacity(0.3),
								radius: 8
							)

						Image(systemName: audioManager.isRecording ? "stop.fill" : "mic.fill")
							.font(.system(size: 24, weight: .semibold))
							.foregroundColor(.white)
					}
				}
				.buttonStyle(.plain)
				.onChange(of: audioManager.isRecording) { _, recording in
					withAnimation(
						recording
							? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
							: .default
					) {
						pulseRecord = recording
					}
				}

				if audioManager.isRecording {
					AudioMeterView(levels: audioManager.audioLevels, fixedHeight: 20)
						.frame(width: 160)
						.transition(.opacity)
				}

				if audioManager.isTranscribing {
					HStack(spacing: 8) {
						ProgressView()
							.scaleEffect(0.8)
						Text("Transcribing...")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}

				Text(audioManager.isRecording ? "Tap to stop" : "Tap to record")
					.font(.caption)
					.foregroundColor(.secondary)
			}

			if let transcription = audioManager.lastTranscription, !transcription.isEmpty {
				VStack(spacing: 12) {
					HStack(spacing: 8) {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.green)
						Text("Transcription Complete")
							.font(.system(.subheadline, design: .rounded, weight: .medium))
							.foregroundColor(.green)
					}

					Text(transcription)
						.font(.body)
						.padding(12)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
						.textSelection(.enabled)

					Button("Copy to Clipboard") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(transcription, forType: .string)
					}
					.buttonStyle(SecondaryButtonStyle())
					.controlSize(.small)
				}
				.padding(16)
				.background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
				.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.animation(.spring(duration: 0.4, bounce: 0.15), value: audioManager.isRecording)
		.animation(.spring(duration: 0.4, bounce: 0.15), value: audioManager.lastTranscription)
	}
}
