// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation

/// The one rule for how wide the live-words HUD may be at any moment.
/// Extracted from `LiveTranscriptionWindow` so the calm-motion contract from
/// the WHI-58 QA session — while a dictation runs the frame may grow, in
/// coarse steps, and never shrinks or hides — is an ordinary unit-tested
/// function instead of something only visible in a screen recording. See
/// DictationHUDWidthTests.
enum DictationHUDWidth {
	/// Where every session starts. Matches the window's historical floor.
	static let compact: CGFloat = 120

	/// Growth quantum. Word-by-word width estimates wobble by a few points on
	/// every update; snapping to this grid means the frame only moves once the
	/// text has outgrown a whole step, not on every word.
	static let step: CGFloat = 48

	/// The width the window should adopt right now.
	///
	/// - `current`: the window's width, nil while it is off screen. A hidden
	///   window has no width to preserve, which is what resets the growth
	///   between dictations.
	/// - `estimated`: the content's estimated natural width.
	/// - `maximum`: the screen-derived ceiling. Once growth reaches it the
	///   frame stops changing entirely and the content handles its own
	///   overflow.
	/// - `isDictating`: while true the result never drops below `current` —
	///   the never-shrink half of the contract.
	static func width(
		current: CGFloat?, estimated: CGFloat, maximum: CGFloat, isDictating: Bool
	) -> CGFloat {
		let ceiling = max(compact, maximum)
		let steps = max(0, ((estimated - compact) / step).rounded(.up))
		let quantized = min(compact + steps * step, ceiling)
		guard isDictating, let current else { return quantized }
		return min(max(quantized, current), ceiling)
	}

	/// Width of the trailing run of words the HUD shows, measured off the same
	/// type `PillWordFlow` renders — body rounded for the run, title3 rounded
	/// semibold for the emphasized last word — instead of priced per character.
	/// The QA session showed why: a flat 9pt/char sat ~30% above what the text
	/// actually needs, and with the never-shrink rule that error only ever
	/// accumulated, leaving half the capsule blank. The step grid above still
	/// absorbs word-to-word wobble; this only has to be honest about the total.
	static func estimatedWidth(words: [String], hasEllipsis: Bool) -> CGFloat {
		var items: [CGFloat] = []
		if hasEllipsis {
			items.append(measure("...", font: Fonts.ellipsis) + 2)
		}
		for (index, word) in words.enumerated() {
			let isLast = index == words.count - 1
			items.append(measure(word, font: isLast ? Fonts.emphasizedWord : Fonts.word))
		}
		let spacing = CGFloat(max(0, items.count - 1)) * 4
		return (items.reduce(0, +) + spacing + horizontalPadding).rounded(.up)
	}

	/// Width of a one-line status row (waiting for model, recipe error): a
	/// 20pt indicator, its 8pt gap, then the text at caption size.
	static func statusWidth(_ text: String) -> CGFloat {
		(measure(text, font: Fonts.status) + 20 + 8 + horizontalPadding).rounded(.up)
	}

	/// DictationView's `.padding(.horizontal, PillSpacing.md)`, both sides.
	private static let horizontalPadding: CGFloat = 24

	private static func measure(_ text: String, font: NSFont) -> CGFloat {
		(text as NSString).size(withAttributes: [.font: font]).width
	}

	/// AppKit equivalents of `PillTypography`: same text styles, same rounded
	/// design, so the measurement tracks what the SwiftUI content lays out.
	private enum Fonts {
		static let word = rounded(.body, weight: .regular)
		static let emphasizedWord = rounded(.title3, weight: .semibold)
		static let ellipsis = rounded(.body, weight: .regular)
		static let status = rounded(.caption1, weight: .regular)

		private static func rounded(_ style: NSFont.TextStyle, weight: NSFont.Weight) -> NSFont {
			let size = NSFont.preferredFont(forTextStyle: style).pointSize
			let base = NSFont.systemFont(ofSize: size, weight: weight)
			guard let descriptor = base.fontDescriptor.withDesign(.rounded),
				let font = NSFont(descriptor: descriptor, size: size)
			else { return base }
			return font
		}
	}
}

/// Whether the HUD has anything to say right now. The window must never sit on
/// screen as an empty capsule — the QA session caught exactly that: a session
/// whose words had not arrived yet held a wide blank surface above the pill.
/// Before the first word the HUD either shows a status line or stays hidden;
/// once words have shown, a momentarily blank transcript keeps the window (and
/// DictationView keeps the held words) until the session ends.
enum DictationHUDContent {
	static func hasSomethingToSay(
		overlayError: String?,
		isWaitingForModel: Bool,
		waitingStatusText: String,
		displayText: String,
		hasShownWordsThisSession: Bool
	) -> Bool {
		if overlayError != nil { return true }
		if isWaitingForModel { return !waitingStatusText.isEmpty }
		return !displayText.isEmpty || hasShownWordsThisSession
	}
}
