import SwiftUI

struct LiveTranscriptionView: View {
	// Bound to the shared live state rather than one engine, so whichever engine
	// is transcribing reaches this view. See WHI-58.
	@Bindable private var live = LiveTranscriptionState.shared

	// Show only the last few words being transcribed
	private var latestWords: String {
		let currentText = live.stableDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !currentText.isEmpty else { return "" }

		// Get the last 6-8 words to show recent context
		let words = currentText.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }

		let maxWords = 8
		let recentWords = words.suffix(maxWords)

		return recentWords.joined(separator: " ")
	}

	var body: some View {
		Group {
			if !latestWords.isEmpty {
				PillWordFlow(words: latestWords.split(separator: " ").map(String.init))
			} else if live.isTranscribing {
				PillStatusRow(indicator: .pulse(.blue), text: "Listening...")
			}
		}
		.padding(.horizontal, PillSpacing.md)
		.padding(.vertical, PillSpacing.sm)
		.animation(.none, value: latestWords)  // No animation to prevent rewrites
		.pillChrome()
	}
}
