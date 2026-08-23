// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Everything the live-transcription HUD reads, owned in one place so every
/// engine feeds the same surface. Extracted from `WhisperKitTranscriber`
/// unchanged: the two-segment confirmation buffer and the flicker filter below
/// are the ones that were already tuned there, and a remote engine reuses them
/// rather than growing a second display path. See WHI-58.
///
/// `WhisperKitTranscriber` forwards its own live properties here, so callers
/// and tests that still speak to the transcriber see exactly what they saw
/// before.
@MainActor
@Observable
final class LiveTranscriptionState {
	static let shared = LiveTranscriptionState()

	/// Text the engine will not revise again. Whoever is typing it into the
	/// focused app watches this.
	var confirmedText: String = "" {
		didSet {
			onConfirmedTextChange?(confirmedText)
		}
	}
	/// UI-facing stable property: only moves when the words meaningfully change.
	var stableDisplayText: String = ""
	var shouldShowLiveTranscriptionWindow: Bool = false
	var isTranscribing: Bool = false
	var isWaitingForModel: Bool = false
	var waitingForModelStatusText: String = ""
	/// The stopped dictation's finalize pass (the two-pass "Polishing…" wait) is
	/// still running. Deliberately a separate channel from `isWaitingForModel`:
	/// that one belongs to the words window for mid-session statuses (waiting for
	/// model, reconnecting), while this one belongs to the listening pill alone —
	/// routing the polish through the waiting channel made both surfaces collapse
	/// into identical "Polishing…" chips at once.
	var isFinalizing: Bool = false
	var finalizingStatusText: String = ""
	var shouldShowDebugWindow: Bool = false
	/// The last failure that needs the user to do something. Presented as an
	/// `.alert()`, never inline: the HUD is one line and the recovery step does not
	/// fit on it. Cleared when the alert is dismissed and when a new session starts.
	var failure: TranscriptionFailure?

	@ObservationIgnored
	var onConfirmedTextChange: ((String) -> Void)?

	/// Internal working property: the words still in flight.
	var pendingText: String = ""
	private var lastDisplayedPendingText: String = ""
	private var lastConfirmedSegmentCount: Int = 0

	var latestWord: String {
		let words = stableDisplayText.split(separator: " ")
		return words.last?.description ?? ""
	}

	/// How many trailing segments stay pending. Whisper revises the tail of its
	/// output as more audio arrives, so confirming it early duplicates words.
	static let requiredSegmentsForConfirmation = 2

	/// A dictation session is running: the engine is transcribing, or holding
	/// the session open behind a status line (waiting for model, reconnecting).
	/// The words window keys its visibility off this. The post-stop finalize
	/// pass is deliberately not part of it — the dictation is over and its words
	/// are final, so the words window must not linger (or come back) to show the
	/// polish; the listening pill is the surface that announces it.
	var isSessionActive: Bool {
		isTranscribing || isWaitingForModel
	}

	// MARK: - Session boundaries

	func reset() {
		isWaitingForModel = false
		waitingForModelStatusText = ""
		isFinalizing = false
		finalizingStatusText = ""
		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		shouldShowLiveTranscriptionWindow = false
		isTranscribing = false
		confirmedText = ""
		shouldShowDebugWindow = false
		lastConfirmedSegmentCount = 0
		failure = nil
	}

	/// Forgets how much of the segment history has been confirmed, so a fresh
	/// stream starts counting from its first segment again.
	func resetSegmentConfirmation() {
		lastConfirmedSegmentCount = 0
	}

	func beginWaiting() {
		pendingText = ""
		stableDisplayText = ""
		lastDisplayedPendingText = ""
		confirmedText = ""
		failure = nil
		// A session that begins waiting is a fresh stream: a confirmation count
		// left over from the previous session would silently swallow the first
		// segments of this one.
		lastConfirmedSegmentCount = 0
		// A new dictation supersedes any pass still pending from the previous
		// one; its status must not survive into this session's pill.
		isFinalizing = false
		finalizingStatusText = ""
		shouldShowLiveTranscriptionWindow = true
		isWaitingForModel = true
		waitingForModelStatusText = "Waiting for model..."
	}

	/// Marks the post-stop finalize pass as running. It touches neither
	/// `isWaitingForModel` nor `shouldShowLiveTranscriptionWindow` on purpose:
	/// the words window has already dismissed at stop, exactly as it does with
	/// the finalizer off, and only the pill renders this channel.
	func beginFinalizing(statusText: String) {
		isFinalizing = true
		finalizingStatusText = statusText
	}

	/// The pass ended — pasted or fell back to the draft — so the pill resumes
	/// its normal end-of-dictation dismissal.
	func endFinalizing() {
		isFinalizing = false
		finalizingStatusText = ""
	}

	/// Promotes whatever is still pending at the end of a session.
	func confirmPending() {
		guard !pendingText.isEmpty else { return }

		// Sync all display properties before confirming to prevent double transcription
		stableDisplayText = pendingText
		lastDisplayedPendingText = pendingText

		// The engine hands back its complete transcription history in pendingText,
		// so we replace confirmedText entirely rather than appending
		confirmedText = pendingText
		pendingText = ""
	}

	// MARK: - Ingest

	/// For an engine that re-transcribes its whole buffer each pass and hands
	/// back the full segment history, WhisperKit-style. Everything but the last
	/// two segments is confirmed, exactly once each.
	func ingest(segmentTexts: [String]) {
		guard !segmentTexts.isEmpty else { return }

		let required = Self.requiredSegmentsForConfirmation

		if segmentTexts.count > required {
			let numberOfSegmentsToConfirm = segmentTexts.count - required

			// Only confirm new segments that haven't been confirmed before
			if numberOfSegmentsToConfirm > lastConfirmedSegmentCount {
				let startIndex = lastConfirmedSegmentCount
				let endIndex = numberOfSegmentsToConfirm
				let newConfirmedText = segmentTexts[startIndex..<endIndex].joined(separator: " ")

				if !newConfirmedText.isEmpty {
					confirmedText =
						confirmedText.isEmpty ? newConfirmedText : confirmedText + " " + newConfirmedText
					lastConfirmedSegmentCount = numberOfSegmentsToConfirm
				}
			}

			setPending(segmentTexts.suffix(required).joined(separator: " "))
		} else {
			setPending(segmentTexts.joined(separator: " "))
		}

		shouldShowLiveTranscriptionWindow = !stableDisplayText.isEmpty || !confirmedText.isEmpty
	}

	/// For an engine that already distinguishes what it has committed from what
	/// is still in flight, so there is nothing to buffer — but the same flicker
	/// filter still decides when the display is allowed to move.
	///
	/// The HUD renders `stableDisplayText` alone, so the committed words have to
	/// be part of it. Displaying only the draft meant every utterance boundary
	/// wiped the whole sentence and restarted from the next utterance's first
	/// word — the disappear-and-reappear the WHI-58 QA session reported. With the
	/// full transcript composed here, the display only ever grows during a
	/// dictation: committed words never leave it, and only the draft tail is
	/// still allowed to be rewritten in flight.
	func ingest(committed: String, draft: String) {
		if committed != confirmedText {
			confirmedText = committed
		}
		pendingText = draft
		let combined = Self.joined(committed: committed, draft: draft)
		if shouldUpdatePendingText(newText: combined) {
			stableDisplayText = combined
			lastDisplayedPendingText = combined
		}
		shouldShowLiveTranscriptionWindow = !stableDisplayText.isEmpty || !confirmedText.isEmpty
	}

	/// One transcript out of the two halves a committed/draft engine reports.
	static func joined(committed: String, draft: String) -> String {
		[committed, draft].filter { !$0.isEmpty }.joined(separator: " ")
	}

	/// Sets the in-flight text, moving the display only when the words changed
	/// enough to be worth a redraw.
	func setPending(_ newPendingText: String) {
		pendingText = newPendingText

		if shouldUpdatePendingText(newText: newPendingText) {
			stableDisplayText = newPendingText
			lastDisplayedPendingText = newPendingText
		}
	}

	/// Suppresses redraws for a tail the engine is only nudging. Whisper rewrites
	/// its last words constantly, and repainting each rewrite makes the HUD
	/// flicker.
	func shouldUpdatePendingText(newText: String) -> Bool {
		// If the text is empty or previous text was non-empty, always update (to handle clearing)
		if newText.isEmpty || lastDisplayedPendingText.isEmpty {
			return true
		}

		let newWords = newText.split(separator: " ").map(String.init)
		let oldWords = lastDisplayedPendingText.split(separator: " ").map(String.init)

		let wordCountDiff = abs(newWords.count - oldWords.count)
		if wordCountDiff > 1 { return true }

		let wordsToCompare = min(3, min(newWords.count, oldWords.count))
		if wordsToCompare > 0 {
			let newLastWords = Array(newWords.suffix(wordsToCompare))
			let oldLastWords = Array(oldWords.suffix(wordsToCompare))

			if newLastWords != oldLastWords {
				return true
			}
		}

		return false
	}
}

/// The draft of the utterance currently in flight, built out of an engine's
/// partial-transcript events. This accumulator exists because those partials
/// are deltas: the OpenAI-Realtime contract
/// (`conversation.item.input_audio_transcription.delta`) sends only the new
/// fragment since the previous event, so handing one fragment straight to the
/// display replaced the pill's tail with the latest few words instead of
/// growing it — the nemo-stream WHI-58 QA bug. Fragments concatenate with no
/// separator injected: the engine carries its own spacing, and a mid-word
/// split like "work" + "ing" must stay one word.
struct UtteranceDraftAccumulator {
	private var fragments = ""

	/// How much of a delta has to overlap the draft's tail before the overlap is
	/// read as a revision rather than a coincidence.
	///
	/// A real append-only delta is a token or two — `"ing"`, `" the"`, `"."` —
	/// and short strings collide by accident all the time: a draft ending
	/// `"…on the"` followed by a genuine `" the mat"` shares four characters and
	/// means nothing by it. A re-sent revised tail is a clause. Eight characters
	/// is comfortably above the one and below the other; it is a threshold, not a
	/// measurement, and it exists so the splice below cannot eat a legitimate
	/// fragment.
	private static let revisionOverlapFloor = 8

	/// The utterance so far, trimmed only at the edges. A fragment often opens
	/// with the space that separates it from the previous one, and a leading
	/// space here would double up against the separator
	/// `LiveTranscriptionState.joined` inserts between the committed text and
	/// this draft. Interior spacing is the engine's own and stays untouched.
	var draft: String {
		fragments.trimmingCharacters(in: .whitespaces)
	}

	/// The engine sent the whole utterance as it now hears it, so the draft is
	/// replaced outright.
	///
	/// This is the path a `DictationEvent.revisedTranscript` takes — the engine
	/// itself said which of the two things it meant, which is always better
	/// evidence than the shape of the text. `append` is the fallback for an
	/// engine that revises without saying so.
	mutating func replace(with hypothesis: String) {
		fragments = hypothesis
	}

	mutating func append(_ delta: String) {
		fragments = Self.merging(fragments, with: delta)
	}

	mutating func clear() {
		fragments = ""
	}

	/// What the draft becomes when `delta` arrives — append, replace, or splice.
	///
	/// Append-only was the whole contract this used to assume: `fragments +=
	/// delta`, on the strength of the OpenAI-Realtime `…transcription.delta`
	/// frame carrying only the new fragment. Engines behind the backend do not
	/// all honour it. One re-sends the entire utterance on every event, another
	/// re-sends a *revised tail* — and glued on with `+=`, both render the
	/// sentence's own prefix twice ("Eh this should be workEh this should be
	/// working"). What reaches the user is that doubled text: `stopStreaming`
	/// pastes the committed transcript plus this draft.
	///
	/// So the decision is made from the text as well as from the event type, in
	/// three rules ordered from most to least certain. Pure and static so the
	/// whole table is exercisable without a session — see
	/// `LiveTranscriptionStateTests`. See WHI-67/69.
	static func merging(_ current: String, with delta: String) -> String {
		let existing = current.trimmingCharacters(in: .whitespaces)
		let incoming = delta.trimmingCharacters(in: .whitespaces)
		guard !incoming.isEmpty else { return current }
		guard !existing.isEmpty else { return delta }

		// 1. A full hypothesis by shape: everything the draft holds is this
		//    delta's own prefix, so the delta *is* the utterance and appending it
		//    would say the prefix twice.
		if incoming.hasPrefix(existing) { return delta }

		// 2. The same tail sent twice — an engine repeating its last frame after a
		//    reconnect, or a proxy replaying it. Nothing to add.
		if existing.hasSuffix(incoming), incoming.count >= revisionOverlapFloor { return current }

		// 3. A revised tail: the delta re-states the end of the draft and carries
		//    on past it. Splice at the overlap so the shared clause is rendered
		//    once. Gated by `revisionOverlapFloor` so an ordinary short fragment
		//    that happens to start the way the draft ends is still appended.
		let overlap = overlapLength(tailOf: existing, headOf: incoming)
		if overlap >= revisionOverlapFloor {
			return existing + String(incoming.dropFirst(overlap))
		}

		return current + delta
	}

	/// The length of the longest string that is both a suffix of `tail` and a
	/// prefix of `head`.
	private static func overlapLength(tailOf tail: String, headOf head: String) -> Int {
		let tail = Array(tail)
		let head = Array(head)
		var length = min(tail.count, head.count)
		while length > 0 {
			if tail.suffix(length).elementsEqual(head.prefix(length)) { return length }
			length -= 1
		}
		return 0
	}
}
