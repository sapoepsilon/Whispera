import SwiftUI

struct DictationView: View {
	@Bindable private var whisperKit = WhisperKitTranscriber.shared
	@State private var coordinator = DictationCoordinator.shared
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
			if let overlayError = coordinator.overlayError {
				DictationNotice(message: overlayError)
					.transition(.opacity.combined(with: .scale(scale: 0.95)))
			} else if whisperKit.isWaitingForModel {
				HStack(spacing: 8) {
					ProgressView()
						.scaleEffect(0.7)
					Text(whisperKit.waitingForModelStatusText)
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.transition(.opacity.combined(with: .scale(scale: 0.95)))
			} else if !whisperKit.stableDisplayText.isEmpty {
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

/// The HUD's error / notice line. Recipe errors are a few words; the
/// blocked-browser notice is a couple of sentences, so the message wraps to a
/// bounded width instead of running off into a clipped single-line strip. Its own
/// type because `LiveTranscriptionWindow` measures this exact view to size the
/// window — a character-count estimate cannot see where the text wraps.
struct DictationNotice: View {
	let message: String

	/// Wrapping width for the message alone. Icon, spacing and padding put the
	/// laid-out overlay a little under 420pt.
	static let maxTextWidth: CGFloat = 360
	private static let font: Font = .system(.caption, design: .rounded)

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(.orange)
				.imageScale(.small)
			Text(message)
				.font(Self.font)
				.foregroundColor(.primary)
				.multilineTextAlignment(.leading)
				.frame(width: Self.textWidth(for: message), alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}

	/// The message's one-line width, capped. Deliberately a *definite* width rather
	/// than `.frame(maxWidth:)`: with a cap SwiftUI derives the ideal height from
	/// the unclamped text, so a wrapped notice reports one line too few and the
	/// enclosing `.fixedSize()` hands the window a height that clips it. With a
	/// definite width the ideal, the laid-out and the window's measured size all
	/// agree, and short recipe errors still shrink to one line.
	@MainActor static func textWidth(for message: String) -> CGFloat {
		if let cached = widthCache[message] { return cached }
		let measured = NSHostingController(rootView: Text(message).font(font).fixedSize())
			.view.fittingSize.width
		let width = min(maxTextWidth, ceil(measured))
		// The HUD sees a handful of distinct messages; the bound is only so a long
		// session of varied recipe errors cannot grow this without limit.
		if widthCache.count > 16 { widthCache.removeAll() }
		widthCache[message] = width
		return width
	}

	@MainActor private static var widthCache: [String: CGFloat] = [:]
}

#Preview {
	DictationView(audioManager: AudioManager())
		.frame(width: 300)
		.padding()
}

#Preview("Notice") {
	DictationNotice(
		message:
			"To pause and resume your browser's video while you dictate, Whispera needs permission: in Brave, enable View > Developer > Allow JavaScript from Apple Events."
	)
	.padding()
}
