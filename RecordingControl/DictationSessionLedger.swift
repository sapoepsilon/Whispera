import Foundation

/// Everything a dictation needs to finish on its own terms. It is captured when the
/// session starts, so a later session can never change how an earlier one is pasted
/// or post-processed.
struct DictationSession: Equatable {
	let id: Int
	let mode: RecordingMode
	let postProcess: Bool
}

/// Tracks the one session that is capturing audio and the sessions whose audio is
/// being transcribed. A session counts as transcribing from the moment capture stops,
/// so the gap before transcription starts (VAD, loading the file) can still be cancelled.
struct DictationSessionLedger {
	private(set) var lastID = 0
	private(set) var capturing: DictationSession?
	private(set) var transcribing: [DictationSession] = []
	private(set) var cancelled: Set<Int> = []

	var isTranscribing: Bool { !transcribing.isEmpty }

	/// Starts a new capture. A previous capture that never reached stop or cancel (its
	/// startup died) is returned as abandoned so its resources can be released.
	mutating func beginCapture(mode: RecordingMode, postProcess: Bool) -> (
		session: DictationSession, abandoned: DictationSession?
	) {
		let abandoned = capturing
		lastID += 1
		let session = DictationSession(id: lastID, mode: mode, postProcess: postProcess)
		capturing = session
		return (session, abandoned)
	}

	/// Capture ended with audio to transcribe; the session moves to the transcribing list.
	@discardableResult
	mutating func finishCapture() -> DictationSession? {
		guard let session = capturing else { return nil }
		capturing = nil
		transcribing.append(session)
		return session
	}

	/// Capture ended with nothing to transcribe, or failed to start.
	@discardableResult
	mutating func dropCapture() -> DictationSession? {
		defer { capturing = nil }
		return capturing
	}

	/// Cancel targets what the user is looking at: the capture when one is running,
	/// otherwise every transcription still in flight. Returns the sessions cancelled.
	mutating func cancel() -> [DictationSession] {
		if let session = capturing {
			capturing = nil
			return [session]
		}
		let sessions = transcribing
		transcribing.removeAll()
		cancelled.formUnion(sessions.map(\.id))
		return sessions
	}

	func isCancelled(_ id: Int) -> Bool {
		cancelled.contains(id)
	}

	func isCapturing(_ id: Int) -> Bool {
		capturing?.id == id
	}

	func isTranscribing(_ id: Int) -> Bool {
		transcribing.contains { $0.id == id }
	}

	/// The session's transcription finished, failed or was abandoned.
	mutating func completeTranscription(_ id: Int) {
		transcribing.removeAll { $0.id == id }
		cancelled.remove(id)
	}
}
