import SwiftUI

struct TestStepView: View {
	@Bindable var audioManager: AudioManager
	@Binding var selectedLanguage: String
	@State private var pulseRecord = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

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
					Text("Auto-detect").tag(Constants.autoDetectLanguageName)
					ForEach(Constants.localizedSortedLanguageNames(), id: \.self) { language in
						Text(Constants.localizedLanguageName(for: language)).tag(language)
					}
				}
				.labelsHidden()
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
				.accessibilityLabel(audioManager.isRecording ? Text("Stop recording") : Text("Start recording"))
				.onChange(of: audioManager.isRecording) { _, recording in
					let pulse = recording && !reduceMotion
					withAnimation(
						pulse
							? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
							: .default
					) {
						pulseRecord = pulse
					}
				}

				if audioManager.isRecording {
					LiveMeter(audioManager: audioManager)
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

				Text(recordHint)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			if let transcription = audioManager.lastTranscription, !transcription.isEmpty {
				VStack(spacing: 12) {
					HStack(spacing: 8) {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.green)
							.accessibilityHidden(true)
						Text("Transcription Complete")
							.font(.system(.subheadline, design: .rounded, weight: .medium))
							.foregroundColor(.primary)
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
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
				.padding(16)
				.background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
				.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
			} else if !audioManager.isRecording, !audioManager.isTranscribing,
				let notice = audioManager.transcriptionError
			{
				InfoBox(style: .warning) {
					Text(notice)
						.font(.caption)
				}
			}
		}
		.animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: audioManager.isRecording)
		.animation(
			reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: audioManager.lastTranscription)
	}

	private var recordHint: LocalizedStringKey {
		audioManager.isRecording ? "Click to stop" : "Click to record"
	}
}

private struct LiveMeter: View {
	// reading audioLevels here keeps the audio-rate invalidation inside this leaf
	// instead of rebuilding the whole step, 100-row language Picker included
	let audioManager: AudioManager

	var body: some View {
		AudioMeterView(levels: audioManager.audioLevels, fixedHeight: 20)
			.frame(width: 160)
	}
}
