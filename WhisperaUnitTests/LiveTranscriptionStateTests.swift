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
	@Test func committedTextBecomesConfirmedAndTheDraftIsDisplayed() {
		let state = LiveTranscriptionState()

		state.ingest(committed: "the quick brown fox", draft: "jumps over")

		#expect(state.confirmedText == "the quick brown fox")
		#expect(state.stableDisplayText == "jumps over")
		#expect(state.shouldShowLiveTranscriptionWindow)
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
