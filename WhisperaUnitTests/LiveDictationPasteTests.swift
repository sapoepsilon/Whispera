// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Testing

@testable import Whispera

/// The paste-once-at-stop decision for live dictation: nothing pastes while
/// words are still arriving (see `DictationWordTracker.handleConfirmedTextChange`
/// and `stopLiveTranscription`'s call site), so the only thing left to decide
/// once a stream closes is whether it produced anything worth pasting. See
/// WHI-58, and PASTE-MODEL-RESULT.md for the fuller decision table this pins.
struct LiveDictationPasteTests {
	@Test func aFullTranscriptIsReturnedTrimmed() {
		#expect(
			AudioManager.textToPaste(afterLiveDictationFinished: "  hello there  ")
				== "hello there")
	}

	@Test func anUntrimmedTranscriptWithNoWhitespaceIsUnchanged() {
		#expect(
			AudioManager.textToPaste(afterLiveDictationFinished: "the quick brown fox")
				== "the quick brown fox")
	}

	@Test func anEmptyTranscriptPastesNothing() {
		#expect(AudioManager.textToPaste(afterLiveDictationFinished: "") == nil)
	}

	@Test func aWhitespaceOnlyTranscriptPastesNothing() {
		#expect(AudioManager.textToPaste(afterLiveDictationFinished: "   \n\t  ") == nil)
	}

	/// A session that fails before confirming any words hands back "" the same
	/// way a session with nothing said does — both engines' `stopStreaming()`
	/// return the empty string in that case, and this function must not
	/// distinguish "failed" from "silent": either way there is nothing to paste.
	@Test func aFailedSessionWithNoWordsPastesNothing() {
		#expect(AudioManager.textToPaste(afterLiveDictationFinished: "") == nil)
	}
}
