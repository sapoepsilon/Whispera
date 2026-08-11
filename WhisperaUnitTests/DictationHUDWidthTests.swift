// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

@testable import Whispera

/// Pins the calm-motion contract for the live-words HUD frame — see the WHI-58
/// QA sessions: while a dictation runs the frame grows immediately in coarse
/// quantized steps, decays one quantum at a time only after the text has
/// stopped needing the width for a sustained beat (the ticker's five-word
/// window is not monotonic, and never-shrink left a permanent blank leading
/// edge), freezes at the ceiling, and starts compact again for the next
/// session. Time is injected, so the hysteresis runs at test speed.
struct DictationHUDWidthTests {
	private let maximum: CGFloat = 600
	private let delay = DictationHUDFrame.shrinkDelay

	private func frame(width: CGFloat, at now: TimeInterval = 0) -> DictationHUDFrame {
		var rule = DictationHUDFrame()
		_ = rule.update(estimated: width, maximum: maximum, isDictating: true, now: now)
		return rule
	}

	@Test func startsCompactForEmptyOrTinyContent() {
		var rule = DictationHUDFrame()
		#expect(
			rule.update(estimated: 0, maximum: maximum, isDictating: true, now: 0)
				== DictationHUDWidth.compact)
		rule.reset()
		#expect(
			rule.update(
				estimated: DictationHUDWidth.compact, maximum: maximum, isDictating: true, now: 0)
				== DictationHUDWidth.compact)
	}

	@Test func growsImmediatelyOnTheStepGridNotPerWord() {
		var rule = DictationHUDFrame()
		#expect(
			rule.update(
				estimated: DictationHUDWidth.compact + 1, maximum: maximum, isDictating: true, now: 0)
				== DictationHUDWidth.compact + DictationHUDWidth.step)

		for estimated in stride(from: 0.0, through: 560.0, by: 13.0) {
			var rule = DictationHUDFrame()
			let width = rule.update(estimated: estimated, maximum: maximum, isDictating: true, now: 0)
			if width < maximum {
				let offGrid = (width - DictationHUDWidth.compact)
					.truncatingRemainder(dividingBy: DictationHUDWidth.step)
				#expect(offGrid == 0, "every width below the ceiling lands on the step grid")
			}
		}
	}

	@Test func smallJitterDoesNotMoveTheFrameAtAll() {
		var rule = frame(width: 200)
		let settled = rule.width
		for (tick, estimated) in [190.0, 205.0, 199.0, 210.0].enumerated() {
			#expect(
				rule.update(
					estimated: estimated, maximum: maximum, isDictating: true,
					now: Double(tick) * 10)
					== settled,
				"a need within one step of the frame never moves it, however long it persists")
		}
	}

	@Test func aMomentaryNarrowTickerDoesNotShrinkTheFrame() {
		var rule = frame(width: 300)
		let grown = rule.update(estimated: 300, maximum: maximum, isDictating: true, now: 0)

		// Narrow for less than the delay, then wide again: no movement at all.
		#expect(rule.update(estimated: 150, maximum: maximum, isDictating: true, now: 0.3) == grown)
		#expect(
			rule.update(estimated: 150, maximum: maximum, isDictating: true, now: 0.3 + delay * 0.9)
				== grown)
		#expect(rule.update(estimated: 300, maximum: maximum, isDictating: true, now: 2 * delay) == grown)
		#expect(
			rule.update(estimated: 150, maximum: maximum, isDictating: true, now: 2 * delay + 0.1)
				== grown,
			"the dip's clock restarts once the text needs the width again")
	}

	@Test func aPersistentGapClosesOneQuantumPerDelayUntilTheFrameHugsTheText() {
		var rule = frame(width: 300)  // quantizes to 312
		let grown = rule.width ?? 0
		let need: CGFloat = 150  // quantizes to 168, three steps below

		#expect(rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1) == grown)
		#expect(
			rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1 + delay)
				== grown - DictationHUDWidth.step)
		#expect(
			rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1 + delay + 0.3)
				== grown - DictationHUDWidth.step,
			"consecutive steps are paced by the delay, not by the caller's tick rate")
		#expect(
			rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1 + 2 * delay)
				== grown - 2 * DictationHUDWidth.step)
		#expect(
			rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1 + 3 * delay)
				== DictationHUDWidth.quantized(need),
			"the decay settles exactly on the text's quantized need")
		#expect(
			rule.update(estimated: need, maximum: maximum, isDictating: true, now: 1 + 10 * delay)
				== DictationHUDWidth.quantized(need),
			"and never undershoots it")
	}

	@Test func growthCancelsAPendingShrink() {
		var rule = frame(width: 300)
		_ = rule.update(estimated: 150, maximum: maximum, isDictating: true, now: 1)
		let wider = rule.update(estimated: 400, maximum: maximum, isDictating: true, now: 1.2)
		#expect(wider > 300, "growth is immediate even with a shrink armed")
		#expect(
			rule.update(estimated: 400, maximum: maximum, isDictating: true, now: 1.2 + delay)
				== wider,
			"the armed shrink is forgotten, not carried into the new width")
	}

	@Test func anEmptyDisplayTextMidDictationHoldsTheFrameThroughTheDelay() {
		var rule = frame(width: 300)
		let grown = rule.width ?? 0
		#expect(
			rule.update(estimated: 0, maximum: maximum, isDictating: true, now: 0.3) == grown,
			"a momentarily blank transcript must not collapse the window")
		#expect(
			rule.update(estimated: 0, maximum: maximum, isDictating: true, now: 0.3 + delay * 0.9)
				== grown)
	}

	@Test func clampsAtTheMaximumAndThenStopsChanging() {
		var rule = DictationHUDFrame()
		let atMax = rule.update(estimated: 5000, maximum: maximum, isDictating: true, now: 0)
		#expect(atMax == maximum)
		#expect(
			rule.update(estimated: 9000, maximum: maximum, isDictating: true, now: 1) == maximum)
		#expect(
			rule.update(estimated: 100, maximum: maximum, isDictating: true, now: 100) == maximum,
			"once at the ceiling the frame never changes again")
	}

	/// `reset()` is the hidden window: nothing to preserve, so the next session
	/// starts from compact no matter how far the previous one grew.
	@Test func aHiddenWindowResetsSoTheNextSessionStartsCompact() {
		var rule = frame(width: 500)
		#expect((rule.width ?? 0) > DictationHUDWidth.compact)
		rule.reset()
		#expect(
			rule.update(estimated: 0, maximum: maximum, isDictating: true, now: 100)
				== DictationHUDWidth.compact)
	}

	@Test func outsideADictationTheWidthIsFreeToShrinkImmediately() {
		var rule = frame(width: 550)
		let width = rule.update(estimated: 130, maximum: maximum, isDictating: false, now: 0.1)
		#expect(width < 550)
		#expect(width == DictationHUDWidth.quantized(130))
	}

	/// The QA screenshot's exact ticker: the old flat 9pt/char price sat far
	/// above what the rendered text needs, and — because the frame never
	/// shrinks mid-dictation — that error accumulated into a capsule whose left
	/// half stayed blank. The estimate now measures the same type PillWordFlow
	/// renders, so the quantized window fits the text and hugs it within one
	/// growth step.
	@Test func estimateHugsTheRenderedTextInsteadOfPricingPerCharacter() {
		let words = ["Space", "there", "There", "are", "no"]
		let measured = DictationHUDWidth.estimatedWidth(words: words, hasEllipsis: true)
		let characters = CGFloat(words.reduce(0) { $0 + $1.count })
		let oldFlatPrice = characters * 9 + CGFloat(words.count - 1) * 4 + 20 + 32
		#expect(measured < oldFlatPrice, "the flat price is what left half the capsule blank")

		var rule = DictationHUDFrame()
		let width = rule.update(
			estimated: measured, maximum: maximum, isDictating: true, now: 0)
		#expect(width >= measured, "the window must fit the text it shows")
		#expect(width - measured < DictationHUDWidth.step, "and hug it within one growth step")
	}

	@Test func estimateGrowsWhenAWordIsAdded() {
		let shorter = DictationHUDWidth.estimatedWidth(
			words: ["hello", "there"], hasEllipsis: false)
		let longer = DictationHUDWidth.estimatedWidth(
			words: ["hello", "there", "general"], hasEllipsis: false)
		#expect(longer > shorter)
	}

	@Test func ellipsisReservesRoom() {
		let without = DictationHUDWidth.estimatedWidth(words: ["hello"], hasEllipsis: false)
		let with = DictationHUDWidth.estimatedWidth(words: ["hello"], hasEllipsis: true)
		#expect(with > without)
	}

	/// A status line ("Waiting for model...") must price out near the compact
	/// floor, not race the frame up two growth steps before a word has arrived.
	@Test func aStatusLineStaysNearTheCompactFloor() {
		var rule = DictationHUDFrame()
		let width = rule.update(
			estimated: DictationHUDWidth.statusWidth("Waiting for model..."),
			maximum: maximum,
			isDictating: true,
			now: 0)
		#expect(width <= DictationHUDWidth.compact + DictationHUDWidth.step)
	}
}

/// The HUD may only be on screen while it has something to say — the WHI-58 QA
/// session photographed a wide, completely empty capsule above the running
/// pill. Before the first word: a status line or nothing. After words: a
/// momentarily blank transcript holds the window (DictationView holds the
/// words), and only the session ending releases it.
struct DictationHUDContentTests {
	@Test func aSessionWithNoWordsYetShowsNothing() {
		#expect(
			!DictationHUDContent.hasSomethingToSay(
				overlayError: nil, isWaitingForModel: false, waitingStatusText: "",
				displayText: "", hasShownWordsThisSession: false))
	}

	@Test func aWaitingStatusLineIsContent() {
		#expect(
			DictationHUDContent.hasSomethingToSay(
				overlayError: nil, isWaitingForModel: true, waitingStatusText: "Connecting…",
				displayText: "", hasShownWordsThisSession: false))
	}

	@Test func waitingWithAnEmptyStatusIsNotContent() {
		#expect(
			!DictationHUDContent.hasSomethingToSay(
				overlayError: nil, isWaitingForModel: true, waitingStatusText: "",
				displayText: "", hasShownWordsThisSession: false))
	}

	@Test func wordsAreContent() {
		#expect(
			DictationHUDContent.hasSomethingToSay(
				overlayError: nil, isWaitingForModel: false, waitingStatusText: "",
				displayText: "hello there", hasShownWordsThisSession: false))
	}

	@Test func aBlankTranscriptAfterWordsHoldsTheWindow() {
		#expect(
			DictationHUDContent.hasSomethingToSay(
				overlayError: nil, isWaitingForModel: false, waitingStatusText: "",
				displayText: "", hasShownWordsThisSession: true))
	}

	@Test func aRecipeErrorIsContent() {
		#expect(
			DictationHUDContent.hasSomethingToSay(
				overlayError: "Recipe failed", isWaitingForModel: false, waitingStatusText: "",
				displayText: "", hasShownWordsThisSession: false))
	}
}
