import SwiftUI

struct DictationView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	private let audioManager: AudioManager

	// Live transcription customization settings
	@AppStorage("liveTranscriptionMaxWords") private var maxWordsToShow = 5
	@AppStorage("liveTranscriptionCornerRadius") private var cornerRadius = 10.0
	@AppStorage("liveTranscriptionShowEllipsis") private var showEllipsis = true

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
	}

	private var displayWords: [(text: String, isLast: Bool)] {
		let words = whisperKit.stableDisplayText
			.split(separator: " ")
			.map(String.init)

		guard !words.isEmpty else { return [] }

		// Take only the last N words
		let wordsToShow = words.suffix(maxWordsToShow)
		let startIndex = words.count - wordsToShow.count

		return wordsToShow.enumerated().map { index, word in
			(text: word, isLast: index == wordsToShow.count - 1)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			if !whisperKit.stableDisplayText.isEmpty {
				HStack(spacing: 4) {
					if showEllipsis
						&& whisperKit.stableDisplayText.split(separator: " ").count > maxWordsToShow
					{
						Text("...")
							.font(.system(.body, design: .rounded))
							.foregroundColor(Color.secondary.opacity(0.6))
							.padding(.trailing, 2)
					}

					ForEach(Array(displayWords.enumerated()), id: \.offset) { _, wordInfo in
						Text(wordInfo.text)
							.font(.system(wordInfo.isLast ? .title3 : .body, design: .rounded))
							.foregroundColor(wordInfo.isLast ? Color.blue : Color.primary.opacity(0.8))
							.fontWeight(wordInfo.isLast ? .semibold : .regular)
							.animation(.easeInOut(duration: 0.15), value: wordInfo.isLast)
					}
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.transition(.opacity.combined(with: .scale(scale: 0.95)))
			} else if whisperKit.isTranscribing {
				ListeningView(audioManager: audioManager)
			}
		}
		.fixedSize()
		.background(
			RoundedRectangle(cornerRadius: cornerRadius)
				.fill(.ultraThinMaterial)
				.overlay(
					RoundedRectangle(cornerRadius: cornerRadius)
						.fill(
							LinearGradient(
								colors: [
									Color.blue.opacity(0.05),
									Color.blue.opacity(0.02),
								],
								startPoint: .topLeading,
								endPoint: .bottomTrailing
							)
						)
				)
		)
		.overlay(
			RoundedRectangle(cornerRadius: cornerRadius)
				.strokeBorder(
					LinearGradient(
						colors: [
							Color.blue.opacity(0.3),
							Color.blue.opacity(0.1),
						],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					),
					lineWidth: 1
				)
		)
		.shadow(color: Color.blue.opacity(0.1), radius: 8, x: 0, y: 2)
		.shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
	}
}

#Preview {
	DictationView(audioManager: AudioManager())
		.frame(width: 300)
		.padding()
}
