import SwiftUI

/// The pill's visual language, factored out of `ListeningView` +
/// `AudioMeterView` so every other pill-family surface (the live-words HUD in
/// `LiveTranscription/`, its Settings preview) composes the same materials,
/// type, spacing and motion instead of re-deriving them. See WHI-58.

/// The spacing scale from design-language.md. Every pill-family surface picks
/// its paddings from here rather than inventing its own numbers.
enum PillSpacing {
	static let xs: CGFloat = 4
	static let sm: CGFloat = 8
	static let md: CGFloat = 12
	static let lg: CGFloat = 16
	static let xl: CGFloat = 20
	static let xxl: CGFloat = 24
}

/// Default corner radius for pre-Liquid-Glass pill surfaces. Individual windows
/// still expose this as a user-tunable `@AppStorage` value; this is only the
/// shared fallback so a fresh install already looks right.
enum PillCornerRadius {
	static let standard: CGFloat = 10
}

/// Typography shared by every pill-family surface: the `.rounded` design that
/// gives the pill its voice, plus the one place that decides what "the word
/// being spoken right now" looks like versus everything around it.
enum PillTypography {
	/// Secondary status lines: "Transcribing...", "Waiting for model...", the
	/// controls tooltip line.
	static let status: Font = .system(.caption, design: .rounded)
	/// The trailing ellipsis shown before a truncated run of words.
	static let ellipsis: Font = .system(.body, design: .rounded)
	/// A word in the live-words flow. The most recently confirmed word is
	/// emphasized so the eye finds it without hunting.
	static func word(emphasized: Bool) -> Font {
		.system(emphasized ? .title3 : .body, design: .rounded)
	}
}

/// What sits to the left of a status line: an indeterminate spinner that
/// settles into a static glyph under Reduce Motion, a pulsing "listening" dot
/// that freezes under Reduce Motion, a static tinted icon, or nothing.
enum PillIndicator {
	case none
	case progress
	case pulse(Color)
	case icon(String, Color)
}

/// One line of secondary status: an optional indicator plus caption text. Used
/// for "preparing model", "waiting for model", "transcribing", "listening" and
/// inline errors — every place a pill-family surface shows a single line of
/// status rather than the live words themselves.
struct PillStatusRow: View {
	var indicator: PillIndicator = .none
	var text: String
	var textColor: Color = .secondary

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var isPulsing = false

	var body: some View {
		HStack(spacing: PillSpacing.sm) {
			indicatorView
			Text(text)
				.font(PillTypography.status)
				.foregroundColor(textColor)
				.lineLimit(2)
		}
		.onAppear {
			if case .pulse = indicator { isPulsing = true }
		}
	}

	@ViewBuilder
	private var indicatorView: some View {
		switch indicator {
		case .none:
			EmptyView()
		case .progress:
			// A spinner is indeterminate motion that never settles, which is
			// exactly what Reduce Motion asks us not to draw. The dot says the
			// same thing — something is in progress — and holds still.
			if reduceMotion {
				Image(systemName: "circle.dotted")
					.imageScale(.small)
					.foregroundColor(.secondary)
			} else {
				ProgressView()
					.scaleEffect(0.7)
					.frame(width: 20, height: 20)
			}
		case .pulse(let color):
			Circle()
				.fill(color)
				.frame(width: 4, height: 4)
				.scaleEffect(reduceMotion ? 1.0 : (isPulsing ? 1.2 : 1.0))
				.animation(
					reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
					value: isPulsing)
		case .icon(let name, let color):
			Image(systemName: name)
				.foregroundColor(color)
				.imageScale(.small)
		}
	}
}

/// The trailing run of live words: recent words at body weight, the most
/// recent one emphasized, optionally preceded by an ellipsis when there is
/// more history than is being shown. Shared by the live-words HUD and its
/// Settings preview so they can never drift apart.
struct PillWordFlow: View {
	var words: [String]
	var showEllipsis: Bool = false

	var body: some View {
		HStack(spacing: PillSpacing.xs) {
			if showEllipsis {
				Text("...")
					.font(PillTypography.ellipsis)
					.foregroundColor(Color.secondary.opacity(0.6))
					.padding(.trailing, 2)
			}

			ForEach(Array(words.enumerated()), id: \.offset) { index, word in
				let isLast = index == words.count - 1
				Text(word)
					.font(PillTypography.word(emphasized: isLast))
					.foregroundColor(isLast ? Color.blue : Color.primary.opacity(0.8))
					.fontWeight(isLast ? .semibold : .regular)
					.animation(.easeInOut(duration: 0.15), value: isLast)
			}
		}
	}
}

/// The pill's background: on macOS 26 the system Liquid Glass, and before that
/// the hand-built material + soft blue border + shadow pair every pill-family
/// surface used to reimplement on its own. One definition, so the listening
/// pill and the live-words HUD cannot visually drift apart again.
struct PillChrome: ViewModifier {
	var cornerRadius: CGFloat = PillCornerRadius.standard

	func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			content.glassEffect()
		} else {
			content
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
}

extension View {
	/// Applies the shared pill chrome (materials, border, shadow / Liquid Glass)
	/// at the given corner radius.
	func pillChrome(cornerRadius: CGFloat = PillCornerRadius.standard) -> some View {
		modifier(PillChrome(cornerRadius: cornerRadius))
	}
}
