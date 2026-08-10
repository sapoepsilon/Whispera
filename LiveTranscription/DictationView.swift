import SwiftUI

struct DictationView: View {
	// Bound to the shared live state rather than one engine, so whichever engine
	// is transcribing reaches this view. See WHI-58.
	@Bindable private var live = LiveTranscriptionState.shared
	@State private var coordinator = DictationCoordinator.shared
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	private let audioManager: AudioManager

	// Live transcription customization settings
	@AppStorage("liveTranscriptionMaxWords") private var maxWordsToShow = 5
	@AppStorage("liveTranscriptionCornerRadius") private var cornerRadius = 10.0
	@AppStorage("liveTranscriptionShowEllipsis") private var showEllipsis = true

	// The last non-empty run of words, held so a display text that blanks for a
	// beat mid-session cannot blink the sentence away — the mid-sentence
	// disappearing the WHI-58 QA session reported. Cleared when the session
	// ends, so a new dictation never opens on the previous one's words.
	@State private var heldWords: [String] = []
	@State private var heldEllipsis = false

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
	}

	private var displayWords: [String] {
		Array(
			live.stableDisplayText
				.split(separator: " ")
				.map(String.init)
				.suffix(maxWordsToShow))
	}

	private var hasHiddenWords: Bool {
		showEllipsis && live.stableDisplayText.split(separator: " ").count > maxWordsToShow
	}

	private var wordsToShow: [String] {
		displayWords.isEmpty ? heldWords : displayWords
	}

	private var ellipsisToShow: Bool {
		displayWords.isEmpty ? heldEllipsis : hasHiddenWords
	}

	// This window is the pill's overlay for the transient things a live session
	// says beyond "I am listening" — the pill underneath already covers that.
	// See RecordingWindowPolicy and PillAnchor.
	var body: some View {
		Group {
			if let overlayError = coordinator.overlayError {
				PillStatusRow(
					indicator: .icon("exclamationmark.triangle.fill", .orange),
					text: overlayError,
					textColor: .primary
				)
				.transition(.opacity.combined(with: .scale(scale: 0.95)))
			} else if live.isWaitingForModel {
				PillStatusRow(indicator: .progress, text: live.waitingForModelStatusText)
					.animation(.easeInOut(duration: 0.2), value: live.waitingForModelStatusText)
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
			} else if !wordsToShow.isEmpty {
				PillWordFlow(words: wordsToShow, showEllipsis: ellipsisToShow)
					// The ticker keeps its natural width and clips at the leading
					// edge: the newest words hug the trailing edge — the half of
					// the sentence the speaker is actually tracking — while older
					// words slide out of view instead of stretching the frame.
					.fixedSize()
					.frame(maxWidth: .infinity, alignment: .trailing)
					.clipped()
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
			}
		}
		.padding(.horizontal, PillSpacing.md)
		.padding(.vertical, PillSpacing.sm)
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: live.isWaitingForModel)
		// The chrome spans the whole window: LiveTranscriptionWindow's frame
		// follows the calm DictationHUDWidth rule, and filling it is what makes
		// the visible pill grow in steady steps instead of re-fitting — and
		// re-centering — around every new word.
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.pillChrome(cornerRadius: cornerRadius)
		.onChange(of: live.stableDisplayText) {
			if !displayWords.isEmpty {
				heldWords = displayWords
				heldEllipsis = hasHiddenWords
			}
		}
		.onChange(of: live.isTranscribing) { _, isTranscribing in
			if !isTranscribing {
				heldWords = []
				heldEllipsis = false
			}
		}
	}
}

#Preview {
	DictationView(audioManager: AudioManager())
		.frame(width: 300)
		.padding()
}
