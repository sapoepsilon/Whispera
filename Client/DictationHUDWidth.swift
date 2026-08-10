// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

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

	/// Width estimate for the trailing run of words the HUD shows. One flat
	/// per-character price, deliberately: the old estimate priced the last
	/// word above the rest (it renders emphasized), so every word changed its
	/// cost the moment the next word arrived and the width wobbled on each
	/// update. A flat price slightly above the body-font average covers the
	/// one emphasized word too, and the step grid above absorbs the remaining
	/// error.
	static func estimatedWidth(words: [String], hasEllipsis: Bool) -> CGFloat {
		let characters = words.reduce(0) { $0 + $1.count }
		let spacing = CGFloat(max(0, words.count - 1)) * 4
		let ellipsis: CGFloat = hasEllipsis ? 20 : 0
		return CGFloat(characters) * 9 + spacing + ellipsis + 32
	}
}
