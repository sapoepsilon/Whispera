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

	/// The pending tail joins the confirmed body rather than replacing it. This
	/// used to expect `"two three"` — the segments before the two-segment pending
	/// window were thrown away at the end of every on-device dictation.
	@Test func confirmPendingPromotesTheTailOntoWhatWasAlreadyConfirmed() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])

		state.confirmPending()

		#expect(state.confirmedText == "one two three")
		#expect(state.pendingText == "")
		#expect(state.stableDisplayText == "one two three")
	}

	@Test func confirmPendingWithNothingPendingLeavesConfirmedTextAlone() {
		let state = LiveTranscriptionState()
		state.ingest(segmentTexts: ["one", "two", "three"])
		state.confirmPending()

		state.confirmPending()

		#expect(state.confirmedText == "one two three")
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

	// MARK: - The delta contract (WHI-67/69)

	/// The regression test. `UtteranceDraftAccumulator.append` was
	/// `fragments += delta` and nothing else, on the strength of the
	/// OpenAI-Realtime promise that a `…transcription.delta` frame carries only
	/// the new fragment. Engines behind the backend do not all keep it: one
	/// re-sends the whole utterance on every event, and glued on with `+=` that
	/// renders the sentence's own prefix once per event.
	///
	/// Revert `append` to `fragments += delta` and this fails with
	/// `"HelloHello worldHello world today"` — the doubled text a user would have
	/// pasted.
	@Test func aFullResendReplacesTheDraftInsteadOfDoublingItsPrefix() {
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append("Hello")
		accumulator.append("Hello world")
		accumulator.append("Hello world today")

		#expect(accumulator.draft == "Hello world today")
	}

	/// The engine revised its own tail and carried on: "should be work" became
	/// "should be working", re-sent with the continuation attached. The shared
	/// clause is rendered once, spliced at the overlap.
	@Test func aRevisedTailIsSplicedRatherThanAppended() {
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append("Eh this")
		accumulator.append(" should be work")
		accumulator.append("this should be working right")

		#expect(accumulator.draft == "Eh this should be working right")
	}

	/// An engine that repeats its last frame — after a reconnect, or through a
	/// proxy that replays it — has nothing new to add.
	@Test func aRepeatedTailIsIgnored() {
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append("the meeting is at four")
		accumulator.append(" is at four")

		#expect(accumulator.draft == "the meeting is at four")
	}

	/// The other half of the contract: an engine that says which it meant is
	/// believed outright, without any text-shape guessing. This is what
	/// `DictationEvent.revisedTranscript` takes.
	@Test func anAnnouncedHypothesisReplacesTheDraftEvenWhenItSharesNoPrefix() {
		var accumulator = UtteranceDraftAccumulator()
		accumulator.append("their going too")

		accumulator.replace(with: "they're going to")

		#expect(accumulator.draft == "they're going to")
	}

	/// The splice must not eat a legitimate short fragment. A draft ending
	/// "…on the" followed by a genuine " the mat" shares four characters by
	/// coincidence, which is below the revision floor — so it appends.
	@Test func aShortCoincidentalOverlapStillAppends() {
		var accumulator = UtteranceDraftAccumulator()

		accumulator.append("the cat sat on the")
		accumulator.append(" the mat")

		#expect(accumulator.draft == "the cat sat on the the mat")
	}

	/// The property that matters, over all three delta dialects at once: whatever
	/// the engine's habit, neither the rendered draft nor the pasted transcript
	/// ever repeats its own prefix.
	@Test func noDialectEverRendersADuplicatedPrefix() {
		let fixtures: [(name: String, deltas: [String], expected: String)] = [
			("append-only", ["The meeting", " is at", " four o'clock."], "The meeting is at four o'clock."),
			(
				"full-resend",
				["The meeting", "The meeting is at", "The meeting is at four o'clock."],
				"The meeting is at four o'clock."
			),
			(
				"mixed",
				["The meeting", " is at", "The meeting is at four", " o'clock."],
				"The meeting is at four o'clock."
			),
		]

		for fixture in fixtures {
			let state = LiveTranscriptionState()
			var accumulator = UtteranceDraftAccumulator()
			state.ingest(committed: "Good morning.", draft: "")
			for delta in fixture.deltas {
				accumulator.append(delta)
				state.ingest(committed: state.confirmedText, draft: accumulator.draft)
			}

			#expect(accumulator.draft == fixture.expected, "\(fixture.name) draft")

			let pasted = LiveTranscriptionState.joined(
				committed: state.confirmedText, draft: state.pendingText
			).trimmingCharacters(in: .whitespacesAndNewlines)
			#expect(pasted == "Good morning. \(fixture.expected)", "\(fixture.name) paste")
			#expect(!repeatsItsOwnPrefix(pasted), "\(fixture.name) pasted a duplicated prefix")
		}
	}

	/// True when the text opens with a phrase it then says again immediately —
	/// the exact shape `fragments += delta` produced against a revising engine.
	private func repeatsItsOwnPrefix(_ text: String) -> Bool {
		let words = text.split(separator: " ")
		guard words.count >= 4 else { return false }
		for length in 2...(words.count / 2)
		where words.prefix(length).elementsEqual(
			words.dropFirst(length).prefix(length))
		{
			return true
		}
		return false
	}

	/// The shim's contract, now that WHI-68 has traced it: `join(deltas)` equals
	/// the `completed` transcript, and the tail is flushed at end of utterance. So
	/// the committed event says the same words the draft already holds — and the
	/// draft has to give way to it rather than be added to it, or `stopStreaming`
	/// pastes committed *plus* a draft that repeats it.
	///
	/// Replays the handler exactly: `.partialTranscript` accumulates,
	/// `.finalTranscript` clears, `.transcript` replaces the committed text.
	@Test func aCompletedUtteranceThatRepeatsItsOwnDeltasIsPastedOnce() {
		let state = LiveTranscriptionState()
		var accumulator = UtteranceDraftAccumulator()
		let deltas = ["The meeting", " is at", " four o'clock."]
		let completed = deltas.joined().trimmingCharacters(in: .whitespaces)

		for delta in deltas {
			accumulator.append(delta)
			state.ingest(committed: state.confirmedText, draft: accumulator.draft)
		}
		#expect(state.pendingText == completed)

		accumulator.clear()
		state.ingest(committed: completed, draft: "")

		#expect(state.pendingText == "")
		let pasted = LiveTranscriptionState.joined(
			committed: state.confirmedText, draft: state.pendingText
		).trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(pasted == completed)
		#expect(!repeatsItsOwnPrefix(pasted))
	}

	/// speaches 0.9.0-rc.3 can emit the same `…transcription.completed` twice for
	/// one conversation item. The package drops the second by item id, but the
	/// client must be idempotent anyway: a whole-transcript event *replaces* the
	/// committed text rather than appending to it, so a duplicate that does get
	/// through cannot double the utterance.
	@Test func aDuplicateCompletedEventDoesNotDoubleTheUtterance() {
		let state = LiveTranscriptionState()
		var accumulator = UtteranceDraftAccumulator()
		let completed = "The meeting is at four o'clock."

		accumulator.append("The meeting is at four o'clock.")
		state.ingest(committed: state.confirmedText, draft: accumulator.draft)

		for _ in 0..<2 {
			accumulator.clear()
			state.ingest(committed: completed, draft: "")
		}

		#expect(state.confirmedText == completed)
		#expect(state.pendingText == "")
		let pasted = LiveTranscriptionState.joined(
			committed: state.confirmedText, draft: state.pendingText
		).trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(pasted == completed)
		#expect(!repeatsItsOwnPrefix(pasted))
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

/// The end of an on-device dictation.
///
/// QA, 2026-08-23: WhisperKit's own final hypothesis was complete, but the paste
/// dropped about 40% of it and `DictationWordTracker` logged "Text filtering
/// logic failed, returning the confirmed text by Whisperkit". The cause was
/// `confirmPending`'s blind `confirmedText = pendingText`: correct for a server
/// engine, which resends the whole utterance, and destructive for WhisperKit,
/// which keeps only the last two segments pending and has already confirmed
/// everything before them. PR #76 fixed the same class of bug on the server
/// path; these pin the on-device half of it.
@MainActor
struct LiveTranscriptionPromotionTests {
	/// The mash-up itself: a long body confirmed segment by segment, a two-word
	/// tail still pending, and the whole thing pasted.
	@Test func aLongOnDeviceDictationKeepsItsBodyAtStop() {
		let state = LiveTranscriptionState()
		let segments = [
			"The quick brown fox", "jumps over the lazy dog", "while the rain",
			"keeps falling on the roof", "and nobody says a word",
		]

		state.ingest(segmentTexts: segments)
		state.confirmPending()

		#expect(state.confirmedText == segments.joined(separator: " "))
	}

	/// Growing history, the way a live stream actually arrives — one more
	/// segment per pass — and then the stop.
	@Test func segmentsArrivingOneAtATimeStillEndUpWhole() {
		let state = LiveTranscriptionState()
		let segments = ["one", "two", "three", "four", "five", "six"]

		for count in 1...segments.count {
			state.ingest(segmentTexts: Array(segments.prefix(count)))
		}
		state.confirmPending()

		#expect(state.confirmedText == "one two three four five six")
	}

	/// The server engine's shape must be untouched: it resends the whole
	/// utterance as the pending text, so promoting it is a replace, not an
	/// append. This is the behaviour PR #76 established.
	@Test func aFullHypothesisStillReplacesRatherThanDoubling() {
		#expect(
			LiveTranscriptionState.promoting(
				confirmed: "the quick brown fox",
				pending: "the quick brown fox jumps over the lazy dog")
				== "the quick brown fox jumps over the lazy dog")
	}

	/// A re-transcription is free to change casing and punctuation, so the same
	/// sentence spelled two ways is still one sentence.
	@Test func aRespelledHypothesisIsStillRecognisedAsTheSameWords() {
		#expect(
			LiveTranscriptionState.promoting(
				confirmed: "the quick brown fox",
				pending: "The quick, brown fox jumps.")
				== "The quick, brown fox jumps.")
	}

	/// A tail that was already promoted once does not get promoted twice.
	@Test func aTailAlreadyHeldIsNotAppendedAgain() {
		#expect(
			LiveTranscriptionState.promoting(
				confirmed: "one two three", pending: "two three") == "one two three")
	}

	/// A revised tail overlapping the confirmed end is spliced, so the shared
	/// clause is rendered once.
	@Test func aRevisedTailIsSplicedRatherThanDoubled() {
		#expect(
			LiveTranscriptionState.promoting(
				confirmed: "he sat on the mat", pending: "on the mat and waited")
				== "he sat on the mat and waited")
	}

	/// A one-word coincidence is not an overlap — the pending words are new and
	/// all of them have to survive.
	@Test func aSingleRepeatedWordIsNotTreatedAsARestatement() {
		#expect(
			LiveTranscriptionState.promoting(confirmed: "give me the", pending: "the report now")
				== "give me the the report now")
	}

	@Test func anEmptySideIsWhicheverSideHasWords() {
		#expect(LiveTranscriptionState.promoting(confirmed: "", pending: "hello") == "hello")
		#expect(LiveTranscriptionState.promoting(confirmed: "hello", pending: "") == "hello")
	}
}
