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
			} else if !live.stableDisplayText.isEmpty {
				PillWordFlow(words: displayWords, showEllipsis: hasHiddenWords)
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
			}
		}
		.padding(.horizontal, PillSpacing.md)
		.padding(.vertical, PillSpacing.sm)
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: live.isWaitingForModel)
		.fixedSize()
		.pillChrome(cornerRadius: cornerRadius)
	}
}

#Preview {
	DictationView(audioManager: AudioManager())
		.frame(width: 300)
		.padding()
}
