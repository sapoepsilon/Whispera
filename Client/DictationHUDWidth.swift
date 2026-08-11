// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation

/// The one rule for how wide the live-words HUD may be at any moment.
/// Extracted from `LiveTranscriptionWindow` so the calm-motion contract from
/// the WHI-58 QA sessions is an ordinary unit-tested function instead of
/// something only visible in a screen recording. See DictationHUDWidthTests.
enum DictationHUDWidth {
	/// Where every session starts. Matches the window's historical floor.
	static let compact: CGFloat = 120

	/// Growth quantum. Word-by-word width estimates wobble by a few points on
	/// every update; snapping to this grid means the frame only moves once the
	/// text has outgrown a whole step, not on every word.
	static let step: CGFloat = 48

	/// The estimate snapped up onto the growth grid.
	static func quantized(_ estimated: CGFloat) -> CGFloat {
		let steps = max(0, ((estimated - compact) / step).rounded(.up))
		return compact + steps * step
	}

	/// Width of the trailing run of words the HUD shows, measured off the same
	/// type `PillWordFlow` renders — body rounded for the run, title3 rounded
	/// semibold for the emphasized last word — instead of priced per character.
	/// The QA session showed why: a flat 9pt/char sat ~30% above what the text
	/// actually needs, and the width rule turned that error into a capsule whose
	/// left half stayed blank. The step grid above still absorbs word-to-word
	/// wobble; this only has to be honest about the total.
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

/// The frame's motion contract, one session at a time: grow fast, shrink slow.
///
/// Growth is immediate and quantized, exactly as before. But the ticker's
/// displayed text — a trailing window of at most five words — is not monotonic:
/// a run of long words scrolls out and the rendered line gets narrower again.
/// Under the old never-shrink rule the frame kept the widest window it had ever
/// seen and the trailing-aligned text left a permanent blank leading edge ("it
/// shows up when it grows", WHI-58 QA follow-up). So a width the content has
/// stopped needing now decays: only after the measured need has sat a full step
/// below the frame for `shrinkDelay`, and then one quantum per further delay,
/// so a momentary short window of words never wiggles the frame but a
/// persistent gap closes itself calmly.
///
/// Time is injected (`now`), never read inside the rule, so the hysteresis is
/// testable at any speed. Unchanged from before: a session starts compact,
/// `reset()` (the window hiding) is what forgets the growth, the frame freezes
/// entirely at the screen-derived ceiling, and outside a dictation the width is
/// free to snap straight to the need.
struct DictationHUDFrame {
	/// How long the need must stay a full step below the frame before the first
	/// shrink, and between consecutive shrink steps.
	static let shrinkDelay: TimeInterval = 1.5

	private(set) var width: CGFloat?
	private var narrowSince: TimeInterval?

	mutating func update(
		estimated: CGFloat, maximum: CGFloat, isDictating: Bool, now: TimeInterval
	) -> CGFloat {
		let ceiling = max(DictationHUDWidth.compact, maximum)
		let need = min(DictationHUDWidth.quantized(estimated), ceiling)

		guard isDictating, let current = width else {
			width = need
			narrowSince = nil
			return need
		}

		// At the ceiling the frame stops changing entirely; the content handles
		// its own overflow.
		guard current < ceiling else {
			narrowSince = nil
			width = ceiling
			return ceiling
		}

		if need > current {
			width = need
			narrowSince = nil
			return need
		}

		if need < current {
			guard let since = narrowSince else {
				narrowSince = now
				return current
			}
			guard now - since >= Self.shrinkDelay else { return current }
			// One quantum, then re-arm: the next step needs the gap to persist
			// through another delay, which paces a multi-step shrink calmly and
			// keeps a 60Hz caller (a pill drag) from draining it in one gesture.
			let next = max(need, current - DictationHUDWidth.step)
			width = next
			narrowSince = now
			return next
		}

		narrowSince = nil
		return current
	}

	/// The hidden window: nothing to preserve, so the next session starts from
	/// compact no matter how far this one grew.
	mutating func reset() {
		width = nil
		narrowSince = nil
	}
}

/// Whether the HUD has anything to say right now. The window must never sit on
/// screen as an empty capsule — the QA session photographed exactly that: a
/// session whose words had not arrived yet held a wide blank surface above the
/// pill. Before the first word the HUD either shows a status line or stays
/// hidden; once words have shown, a momentarily blank transcript keeps the
/// window (and DictationView keeps the held words) until the session ends.
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
