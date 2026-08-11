// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Testing

@testable import Whispera

/// Pins the two-segment confirmation buffer and the flicker filter that were
/// extracted out of WhisperKitTranscriber, so a future engine cannot quietly
/// change how live text is confirmed. See WHI-58.
@MainActor
struct LiveTranscriptionSegmentBufferTests {
	@Test func fewerSegmentsThanTheBufferConfirmsNothing() {
		let state = LiveTranscriptionState()

		state.ingest(segmentTexts: ["hello", "there"])

		#expect(state.confirmedText == "")
		#expect(state.pendingText == "hello there")
		#expect(state.stableDisplayText == "hello there")
		#expect(state.shouldShowLiveTranscriptionWindow)
	}

	@Test func everythingBeforeTheLastTwoSegmentsIsConfirmed() {
		let state = LiveTranscriptionState()

		state.ingest(segmentTexts: ["one", "two", "three"])

		#expect(state.confirmedText == "one")
		#expect(state.pendingText == "two three")
	}

	@Test func asegmentIsNeverConfirmedTwice() {
		let state = LiveTranscriptionState()

		state.ingest(segmentTexts: ["one", "two", "three"])
		state.ingest(segmentTexts: ["one", "two", "three"])

		#expect(state.confirmedText == "one")
	}

	@Test func growingHistoryAppendsOnlyTheNewlySettledSegments() {
		let state = LiveTranscriptionState()

		state.ingest(segmentTexts: ["one", "two", "three"])
		state.ingest(segmentTexts: ["one", "two", "three", "four", "five"])

		#expect(state.confirmedText == "one two three")
		#expect(state.pendingText == "four five")
	}

	@Test func anEmptySegmentListLeavesTheStateAlone() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])

		state.ingest(segmentTexts: [])

		#expect(state.confirmedText == "one")
		#expect(state.pendingText == "two three")
	}

	@Test func resettingLetsTheNextStreamConfirmFromItsFirstSegment() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])

		state.reset()
		state.ingest(segmentTexts: ["alpha", "beta", "gamma"])

		#expect(state.confirmedText == "alpha")
		#expect(state.pendingText == "beta gamma")
	}

	@Test func resetClearsEveryDisplayProperty() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])
		state.isWaitingForModel = true
		state.waitingForModelStatusText = "Loading..."

		state.reset()

		#expect(state.confirmedText == "")
		#expect(state.pendingText == "")
		#expect(state.stableDisplayText == "")
		#expect(!state.shouldShowLiveTranscriptionWindow)
		#expect(!state.isTranscribing)
		#expect(!state.isWaitingForModel)
		#expect(state.waitingForModelStatusText == "")
	}

	@Test func beginWaitingShowsTheWindowWithNoText() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])

		state.beginWaiting()

		#expect(state.confirmedText == "")
		#expect(state.stableDisplayText == "")
		#expect(state.shouldShowLiveTranscriptionWindow)
		#expect(state.isWaitingForModel)
		#expect(state.waitingForModelStatusText == "Waiting for model...")
	}

	@Test func confirmPendingPromotesTheTailAndEmptiesIt() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])

		state.confirmPending()

		#expect(state.confirmedText == "two three")
		#expect(state.pendingText == "")
		#expect(state.stableDisplayText == "two three")
	}

	@Test func confirmPendingWithNothingPendingLeavesConfirmedTextAlone() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])
		state.confirmPending()

		state.confirmPending()

		#expect(state.confirmedText == "two three")
	}

	@Test func confirmedTextChangesAreAnnouncedOnce() {
		let state = LiveTranscriptionState()
		var announced: [String] = []
		state.onConfirmedTextChange = { announced.append($0) }

		state.ingest(segmentTexts: ["one", "two", "three"])
		state.ingest(segmentTexts: ["one", "two", "three"])

		#expect(announced == ["one"])
	}
}

@MainActor
struct LiveTranscriptionFlickerFilterTests {
	@Test func theFirstWordsAlwaysReachTheDisplay() {
		let state = LiveTranscriptionState()

		state.setPending("hello world")

		#expect(state.stableDisplayText == "hello world")
	}

	/// A rewrite that leaves the last three words and the word count alone is
	/// the engine nudging its own output, not new speech.
	@Test func aRewriteOfTheHeadDoesNotMoveTheDisplay() {
		let state = LiveTranscriptionState()
		state.setPending("alpha beta gamma delta")

		state.setPending("omega beta gamma delta")

		#expect(state.pendingText == "omega beta gamma delta")
		#expect(state.stableDisplayText == "alpha beta gamma delta")
	}

	@Test func newWordsAtTheTailMoveTheDisplay() {
		let state = LiveTranscriptionState()
		state.setPending("alpha beta gamma")

		state.setPending("alpha beta delta")

		#expect(state.stableDisplayText == "alpha beta delta")
	}

	@Test func clearingAlwaysReachesTheDisplay() {
		let state = LiveTranscriptionState()
		state.setPending("alpha beta gamma")

		state.setPending("")

		#expect(state.stableDisplayText == "")
	}
}

/// The path a server-side engine uses: it already knows what it has committed,
/// so nothing is buffered, but the display still moves on the same rule.
@MainActor
struct LiveTranscriptionRemoteIngestTests {
	@Test func theDisplayCarriesTheCommittedWordsAndTheDraft() {
		let state = LiveTranscriptionState()

		state.ingest(committed: "the quick brown fox", draft: "jumps over")

		#expect(state.confirmedText == "the quick brown fox")
		#expect(state.pendingText == "jumps over")
		#expect(state.stableDisplayText == "the quick brown fox jumps over")
		#expect(state.shouldShowLiveTranscriptionWindow)
	}

	/// The sequence a native-delta engine produces, as observed in the WHI-58 QA
	/// session: word-by-word partials, the utterance finalizes and the whole
	/// accumulated transcript arrives, then the next utterance's partials begin.
	/// The display must only ever grow — committed words never vanish at an
	/// utterance boundary.
	@Test func theDisplayOnlyGrowsAcrossAnUtteranceBoundary() {
		let state = LiveTranscriptionState()
		var displays: [String] = []
		// Mirrors StreamingTranscriber.handle: each `partial` here stands for the
		// draft the transcriber has accumulated out of its delta events so far;
		// .transcript carries the whole accumulated text.
		func partial(_ draft: String) {
			state.ingest(committed: state.confirmedText, draft: draft)
			displays.append(state.stableDisplayText)
		}
		func transcript(_ whole: String) {
			state.ingest(committed: whole, draft: "")
			displays.append(state.stableDisplayText)
		}

		partial("Hello")
		partial("Hello there.")
		transcript("Hello there.")
		partial("General")
		partial("General Kenobi.")
		transcript("Hello there. General Kenobi.")

		for (previous, next) in zip(displays, displays.dropFirst()) {
			#expect(next.hasPrefix(previous))
		}
		#expect(state.stableDisplayText == "Hello there. General Kenobi.")
		#expect(state.confirmedText == "Hello there. General Kenobi.")
	}

	/// The whole-transcript event already contains the utterance that just
	/// finalized; it must not appear a second time as a leftover draft.
	@Test func theWholeTranscriptEventDoesNotRepeatTheFinalizedUtterance() {
		let state = LiveTranscriptionState()

		state.ingest(committed: "", draft: "Hello.")
		state.ingest(committed: "Hello.", draft: "")

		#expect(state.stableDisplayText == "Hello.")
		#expect(state.confirmedText == "Hello.")
		#expect(state.pendingText == "")
	}

	/// What stop pastes: the committed words plus any draft still in flight —
	/// for a native-delta engine the draft is real words the user spoke.
	@Test func stopComposesCommittedAndDraftIntoOneTranscript() {
		#expect(
			LiveTranscriptionState.joined(committed: "Hello there.", draft: "General")
				== "Hello there. General")
		#expect(LiveTranscriptionState.joined(committed: "", draft: "Hello") == "Hello")
		#expect(LiveTranscriptionState.joined(committed: "Hello", draft: "") == "Hello")
		#expect(LiveTranscriptionState.joined(committed: "", draft: "") == "")
	}

	@Test func anUnchangedCommitIsNotAnnouncedAgain() {
		let state = LiveTranscriptionState()
		var announced: [String] = []
		state.onConfirmedTextChange = { announced.append($0) }

		state.ingest(committed: "hello", draft: "there")
		state.ingest(committed: "hello", draft: "there again")

		#expect(announced == ["hello"])
	}

	@Test func aGrowingTranscriptIsAnnouncedInFull() {
		let state = LiveTranscriptionState()
		var announced: [String] = []
		state.onConfirmedTextChange = { announced.append($0) }

		state.ingest(committed: "hello", draft: "")
		state.ingest(committed: "hello there", draft: "")

		#expect(announced == ["hello", "hello there"])
	}
}

/// The transcriber-side accumulation of `.partialTranscript` deltas. A partial
/// carries only the fragment since the previous event, so the transcriber
/// appends it into `UtteranceDraftAccumulator` before handing the draft to the
/// live state; showing a fragment alone replaced the pill's tail instead of
/// growing it. These tests replay the exact event sequence recorded in the
/// WHI-58 nemo-stream QA session through the same logic the handler runs.
@MainActor
struct UtteranceDraftAccumulatorTests {
	@Test func fragmentsConcatenateWithoutASeparator() {
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append(" should be work")
		accumulator.append("ing right")

		#expect(accumulator.draft == "should be working right")
	}

	@Test func clearingStartsTheNextUtteranceEmpty() {
		var accumulator = UtteranceDraftAccumulator()
		accumulator.append("Hello, hello")

		accumulator.clear()

		#expect(accumulator.draft == "")
	}

	@Test func theExactQAEventSequenceGrowsThePillInsteadOfReplacingItsTail() {
		let state = LiveTranscriptionState()
		var accumulator = UtteranceDraftAccumulator()
		// Mirrors StreamingTranscriber.handle for a native-delta engine.
		func partialTranscript(_ delta: String) {
			accumulator.append(delta)
			state.ingest(committed: state.confirmedText, draft: accumulator.draft)
		}
		func finalTranscript() { accumulator.clear() }
		func transcript(_ whole: String) {
			accumulator.clear()
			state.ingest(committed: whole, draft: "")
		}

		partialTranscript("Hello, hello")
		partialTranscript(".")
		finalTranscript()
		transcript("Hello, hello.")

		#expect(state.stableDisplayText == "Hello, hello.")
		#expect(state.confirmedText == "Hello, hello.")
		#expect(state.pendingText == "")

		partialTranscript("Eh this")
		partialTranscript(" should be work")
		partialTranscript("ing right")
		partialTranscript(", yep.")

		#expect(state.pendingText == "Eh this should be working right, yep.")
		#expect(state.stableDisplayText == "Hello, hello. Eh this should be working right, yep.")

		partialTranscript("  It is.")

		#expect(state.pendingText == "Eh this should be working right, yep.  It is.")

		// Stopping mid-utterance pastes committed plus the accumulated draft,
		// exactly as stopStreaming composes them from the live state.
		let pasted = LiveTranscriptionState.joined(
			committed: state.confirmedText, draft: state.pendingText
		).trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(pasted == "Hello, hello. Eh this should be working right, yep.  It is.")
	}

	@Test func aWholeTranscriptAfterAccumulatedPartialsShowsTheUtteranceOnce() {
		let state = LiveTranscriptionState()
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append("Hello, hello")
		state.ingest(committed: state.confirmedText, draft: accumulator.draft)
		accumulator.append(".")
		state.ingest(committed: state.confirmedText, draft: accumulator.draft)
		// finalTranscript clears; the whole-transcript event clears again and
		// commits — the second clear must be harmless.
		accumulator.clear()
		accumulator.clear()
		state.ingest(committed: "Hello, hello.", draft: accumulator.draft)

		#expect(state.stableDisplayText == "Hello, hello.")
		#expect(state.pendingText == "")
	}
}

/// Back-to-back dictations through the real state object — the WHI-58 QA
/// session found words no longer appearing after a couple of consecutive
/// dictations. Each test replays the exact call sequence the engines make at
/// session boundaries and pins that the next session opens clean and shows its
/// first words.
@MainActor
struct LiveTranscriptionBackToBackSessionTests {
	/// The delta-engine cycle: startStreaming's beginWaiting, the .listening
	/// handler, partials, then stopStreaming's exact stop sequence — twice.
	@Test func aSecondDeltaSessionOpensCleanAndShowsItsFirstWords() {
		let state = LiveTranscriptionState()

		state.beginWaiting()
		state.isWaitingForModel = false
		state.isTranscribing = true
		state.ingest(committed: "", draft: "Hello world")
		#expect(state.stableDisplayText == "Hello world")

		state.isTranscribing = false
		state.ingest(committed: "Hello world", draft: "")
		state.setPending("")
		state.shouldShowLiveTranscriptionWindow = false

		state.beginWaiting()
		#expect(state.stableDisplayText.isEmpty, "no leftover words from the previous session")
		#expect(state.confirmedText.isEmpty, "no leftover confirmation from the previous session")
		state.isWaitingForModel = false
		state.isTranscribing = true
		state.ingest(committed: state.confirmedText, draft: "Again")

		#expect(state.stableDisplayText == "Again", "the new session's first words must appear")
	}

	/// A segment engine that starts its next session through beginWaiting alone
	/// must still confirm from its first segment: a confirmation count left
	/// over from the previous session would silently swallow the new session's
	/// opening words from the confirmed text.
	@Test func beginWaitingResetsTheSegmentConfirmationCount() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three", "four", "five"])
		#expect(state.confirmedText == "one two three")

		state.beginWaiting()
		state.ingest(segmentTexts: ["a", "b", "c"])

		#expect(state.confirmedText == "a")
		#expect(state.pendingText == "b c")
	}

	/// The flicker filter compares against the last displayed text; a stale
	/// value surviving the session boundary could suppress the next session's
	/// first (short) update. beginWaiting must leave the filter wide open.
	@Test func theFlickerFilterCannotSuppressANewSessionsFirstWord() {
		let state = LiveTranscriptionState()
		state.ingest(committed: "", draft: "Thank you")

		state.beginWaiting()

		#expect(state.shouldUpdatePendingText(newText: "Thank"))
	}
}

/// After stop, exactly one surface communicates the two-pass polish: the
/// listening pill. The 2026-08-10 QA screenshot showed two "Polishing…"
/// spinner chips at once because stop routed the pass through the same
/// isWaitingForModel channel both windows render. These tests replay the
/// engine's exact call sequences through the real state object and pin that
/// the words window's gate goes down at stop and stays down through the pass,
/// while the pill's finalize channel carries the status until the paste lands.
@MainActor
struct LiveTranscriptionFinalizePassTests {
	/// The words window's show decision, composed exactly as
	/// LiveTranscriptionWindow composes it each poll tick: the session gate,
	/// the transcriber's own wish, and the has-content rule.
	private func wordsWindowWantsVisible(
		_ state: LiveTranscriptionState, hasShownWordsThisSession: Bool = true
	) -> Bool {
		state.isSessionActive && state.shouldShowLiveTranscriptionWindow
			&& DictationHUDContent.hasSomethingToSay(
				overlayError: nil,
				isWaitingForModel: state.isWaitingForModel,
				waitingStatusText: state.waitingForModelStatusText,
				displayText: state.stableDisplayText,
				hasShownWordsThisSession: hasShownWordsThisSession)
	}

	/// A running dictation with words on screen: startStreaming's beginWaiting,
	/// the .listening handler, then a partial.
	private func dictate(_ state: LiveTranscriptionState) {
		state.beginWaiting()
		state.isWaitingForModel = false
		state.waitingForModelStatusText = ""
		state.isTranscribing = true
		state.ingest(committed: "", draft: "Hello world")
	}

	/// stopStreaming's exact live-state sequence, with the finalizer on.
	private func stopWithPolish(_ state: LiveTranscriptionState) {
		state.isWaitingForModel = false
		state.waitingForModelStatusText = ""
		state.isTranscribing = false
		let transcript = LiveTranscriptionState.joined(
			committed: state.confirmedText, draft: state.pendingText
		).trimmingCharacters(in: .whitespacesAndNewlines)
		if !transcript.isEmpty {
			state.ingest(committed: transcript, draft: "")
		}
		state.setPending("")
		state.shouldShowLiveTranscriptionWindow = false
		state.beginFinalizing(statusText: "Polishing…")
	}

	@Test func theWordsWindowGoesDownAtStopAndStaysDownThroughThePolish() {
		let state = LiveTranscriptionState()
		dictate(state)
		#expect(wordsWindowWantsVisible(state), "the running dictation shows its words")

		stopWithPolish(state)

		#expect(!wordsWindowWantsVisible(state), "the words window dismisses at stop")
		#expect(
			!state.isSessionActive,
			"the polish is not a session: the gate must not hold the window up through it")

		state.endFinalizing()
		#expect(!wordsWindowWantsVisible(state), "and it does not come back when the paste lands")
	}

	@Test func thePillCarriesThePolishStatusUntilThePasteLands() {
		let state = LiveTranscriptionState()
		dictate(state)

		stopWithPolish(state)
		#expect(state.isFinalizing)
		#expect(state.finalizingStatusText == "Polishing…")
		#expect(
			!state.isWaitingForModel,
			"the polish must not ride the waiting channel the words window renders")

		state.endFinalizing()
		#expect(!state.isFinalizing)
		#expect(state.finalizingStatusText.isEmpty)
	}

	/// With the finalizer off, stop makes the same sequence minus
	/// beginFinalizing; the window comes down identically and no finalize
	/// status ever appears.
	@Test func theOffPathIsUnchanged() {
		let state = LiveTranscriptionState()
		dictate(state)

		state.isWaitingForModel = false
		state.waitingForModelStatusText = ""
		state.isTranscribing = false
		state.ingest(committed: "Hello world", draft: "")
		state.setPending("")
		state.shouldShowLiveTranscriptionWindow = false

		#expect(!wordsWindowWantsVisible(state))
		#expect(!state.isFinalizing)
		#expect(state.finalizingStatusText.isEmpty)
	}

	/// A rapid next dictation supersedes the pending pass; its pill must open
	/// on the new session's status, not the stale "Polishing…".
	@Test func theNextDictationResetsThePendingPolish() {
		let state = LiveTranscriptionState()
		dictate(state)
		stopWithPolish(state)

		state.beginWaiting()

		#expect(!state.isFinalizing)
		#expect(state.finalizingStatusText.isEmpty)
		#expect(state.isSessionActive, "the new session owns the words window again")
		#expect(wordsWindowWantsVisible(state, hasShownWordsThisSession: false))
	}

	@Test func resetClearsThePendingPolish() {
		let state = LiveTranscriptionState()
		state.beginFinalizing(statusText: "Polishing…")

		state.reset()

		#expect(!state.isFinalizing)
		#expect(state.finalizingStatusText.isEmpty)
	}

	/// The session gate itself, pinned directly: mid-session statuses keep the
	/// words window alive, the finalize pass does not.
	@Test func isSessionActiveExcludesTheFinalizePass() {
		let state = LiveTranscriptionState()
		#expect(!state.isSessionActive)

		state.isTranscribing = true
		#expect(state.isSessionActive)

		state.isTranscribing = false
		state.isWaitingForModel = true
		#expect(state.isSessionActive, "reconnecting and waiting-for-model hold the session open")

		state.isWaitingForModel = false
		state.isFinalizing = true
		#expect(!state.isSessionActive)
	}
}
