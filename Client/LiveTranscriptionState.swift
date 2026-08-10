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

	// MARK: - Session boundaries

	func reset() {
		isWaitingForModel = false
		waitingForModelStatusText = ""
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
		shouldShowLiveTranscriptionWindow = true
		isWaitingForModel = true
		waitingForModelStatusText = "Waiting for model..."
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

	/// The utterance so far, trimmed only at the edges. A fragment often opens
	/// with the space that separates it from the previous one, and a leading
	/// space here would double up against the separator
	/// `LiveTranscriptionState.joined` inserts between the committed text and
	/// this draft. Interior spacing is the engine's own and stays untouched.
	var draft: String {
		fragments.trimmingCharacters(in: .whitespaces)
	}

	mutating func append(_ delta: String) {
		fragments += delta
	}

	mutating func clear() {
		fragments = ""
	}
}
