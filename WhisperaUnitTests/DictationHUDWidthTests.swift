// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

@testable import Whispera

/// Pins the calm-motion contract for the live-words HUD frame — see WHI-58 QA:
/// while a dictation runs the window may only grow, in coarse quantized steps,
/// stops entirely at the ceiling, and starts compact again for the next
/// session. Pure functions, so the contract holds without standing up a window.
struct DictationHUDWidthTests {
	private let maximum: CGFloat = 600

	@Test func startsCompactForEmptyOrTinyContent() {
		#expect(
			DictationHUDWidth.width(current: nil, estimated: 0, maximum: maximum, isDictating: true)
				== DictationHUDWidth.compact)
		#expect(
			DictationHUDWidth.width(
				current: nil, estimated: DictationHUDWidth.compact, maximum: maximum, isDictating: true)
				== DictationHUDWidth.compact)
	}

	@Test func growsOnTheStepGridNotPerWord() {
		let width = DictationHUDWidth.width(
			current: nil, estimated: DictationHUDWidth.compact + 1, maximum: maximum, isDictating: true)
		#expect(width == DictationHUDWidth.compact + DictationHUDWidth.step)

		for estimated in stride(from: 0.0, through: 560.0, by: 13.0) {
			let width = DictationHUDWidth.width(
				current: nil, estimated: estimated, maximum: maximum, isDictating: true)
			if width < maximum {
				let offGrid = (width - DictationHUDWidth.compact)
					.truncatingRemainder(dividingBy: DictationHUDWidth.step)
				#expect(offGrid == 0, "every width below the ceiling lands on the step grid")
			}
		}
	}

	@Test func neverShrinksWhileDictating() {
		// A wobbling estimate, like the per-word pricing produces as words stop
		// being last: the resulting frame must be monotonic anyway.
		var current: CGFloat?
		for estimated in [140.0, 210.0, 180.0, 320.0, 60.0, 340.0] {
			let next = DictationHUDWidth.width(
				current: current, estimated: estimated, maximum: maximum, isDictating: true)
			if let previous = current {
				#expect(next >= previous, "the frame may grow mid-dictation, never shrink")
			}
			current = next
		}
	}

	@Test func smallJitterDoesNotMoveTheFrameAtAll() {
		let settled = DictationHUDWidth.width(
			current: nil, estimated: 200, maximum: maximum, isDictating: true)
		for estimated in [190.0, 205.0, 199.0, 210.0] {
			#expect(
				DictationHUDWidth.width(
					current: settled, estimated: estimated, maximum: maximum, isDictating: true)
					== settled)
		}
	}

	@Test func anEmptyDisplayTextMidDictationHoldsTheFrame() {
		let grown = DictationHUDWidth.width(
			current: nil, estimated: 300, maximum: maximum, isDictating: true)
		#expect(
			DictationHUDWidth.width(current: grown, estimated: 0, maximum: maximum, isDictating: true)
				== grown,
			"a momentarily blank transcript must not collapse the window")
	}

	@Test func clampsAtTheMaximumAndThenStopsChanging() {
		let atMax = DictationHUDWidth.width(
			current: nil, estimated: 5000, maximum: maximum, isDictating: true)
		#expect(atMax == maximum)
		#expect(
			DictationHUDWidth.width(current: atMax, estimated: 9000, maximum: maximum, isDictating: true)
				== maximum,
			"once at the ceiling the frame never changes again")
	}

	/// `current == nil` is the hidden window: nothing to preserve, so the next
	/// session starts from compact no matter how far the previous one grew.
	@Test func aHiddenWindowResetsSoTheNextSessionStartsCompact() {
		let grown = DictationHUDWidth.width(
			current: nil, estimated: 500, maximum: maximum, isDictating: true)
		#expect(grown > DictationHUDWidth.compact)
		#expect(
			DictationHUDWidth.width(current: nil, estimated: 0, maximum: maximum, isDictating: true)
				== DictationHUDWidth.compact)
	}

	@Test func outsideADictationTheWidthIsFreeToShrink() {
		let width = DictationHUDWidth.width(
			current: 552, estimated: 130, maximum: maximum, isDictating: false)
		#expect(width < 552)
	}

	@Test func estimateIsFlatPerCharacterSoWordOrderCannotWobbleIt() {
		let a = DictationHUDWidth.estimatedWidth(words: ["hello", "world"], hasEllipsis: false)
		let b = DictationHUDWidth.estimatedWidth(words: ["world", "hello"], hasEllipsis: false)
		#expect(a == b, "which word is last must not change the estimate")
	}

	@Test func ellipsisReservesRoom() {
		let without = DictationHUDWidth.estimatedWidth(words: ["hello"], hasEllipsis: false)
		let with = DictationHUDWidth.estimatedWidth(words: ["hello"], hasEllipsis: true)
		#expect(with > without)
	}
}
