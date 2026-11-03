import Foundation

/// Where the session is.
public enum DictationConnectionState: Sendable, Equatable {
	case idle
	case connecting
	/// The socket died mid-dictation and another attempt is being made. Emitted
	/// rather than swallowed because audio spoken during the gap is lost, and a
	/// user talking into a gap they cannot see is the failure this whole path
	/// exists to prevent. `attempt` counts from 1.
	case reconnecting(attempt: Int)
	/// The socket is open and the engine has acknowledged the session. Audio is
	/// only sent from this point — frames sent earlier are queued by the proxy, but
	/// relying on that would be relying on an implementation detail of the relay.
	case listening
	/// Audio has ended; waiting for the engine to commit what it heard.
	case finishing
	case closed(DictationCloseReason)
}

public enum DictationCloseReason: Sendable, Equatable {
	case finished
	case cancelled
	case failed(DictationError)
}

/// Everything a host needs to drive a UI.
///
/// One stream rather than a delegate with six methods: a host that only wants text
/// pattern-matches one case and ignores the rest, and adding an event later does
/// not break every existing conformance.
public enum DictationEvent: Sendable, Equatable {
	case connectionState(DictationConnectionState)
	/// A *fragment* of the utterance in flight: only the text new since the
	/// previous event. Not every engine emits these — speaches commits per
	/// utterance — so a host must not depend on seeing one.
	///
	/// Appended by a host, never assigned. See `revisedTranscript` for the other
	/// half of the contract.
	case partialTranscript(String)
	/// The *whole* utterance in flight as the engine currently hears it, replacing
	/// everything it has said about this utterance so far.
	///
	/// Separate from `partialTranscript` because the two cannot be told apart from
	/// the text alone, and guessing wrong is not a cosmetic error: appending a full
	/// hypothesis to the draft it revises renders the sentence's own prefix twice,
	/// and that doubled text is what the host pastes. The engine says which it
	/// means — an OpenAI-Realtime `…transcription.delta` frame carries the fragment
	/// in `delta` and a full hypothesis in `transcript` — so this package reports
	/// the distinction rather than making the host re-derive it. See WHI-67/69.
	case revisedTranscript(String)
	/// One committed utterance.
	case finalTranscript(String)
	/// Everything committed so far, joined. The convenience for hosts that want to
	/// bind a text field to the whole transcript rather than assemble it.
	case transcript(String)
	/// Input level in 0…1, for meters. Emitted per audio chunk.
	case audioLevel(Float)
	case failed(DictationError)
}

public enum DictationError: Error, Sendable, Equatable, LocalizedError {
	/// The credential was rejected. Raised only after the one permitted retry with
	/// a freshly-minted credential also failed.
	case unauthorized
	case credentialUnavailable(String)
	case connectionFailed(String)
	case closedUnexpectedly(code: Int, reason: String)
	case protocolViolation(String)
	case audioUnavailable(String)
	case server(message: String, code: String?)

	/// Whether opening a new socket could plausibly help.
	///
	/// The distinction is the whole reason a reconnect is safe to have at all. A
	/// credential the server rejected after a refresh, a credential that could not
	/// be obtained, an engine speaking a protocol this package does not, and a
	/// microphone that will not open are all facts about the world that a second
	/// attempt cannot change — retrying them hides a persistent failure behind a
	/// spinner. A server error, an unexpected close and a dropped connection are
	/// about *this* socket, and a fresh one may well work.
	public var isRecoverable: Bool {
		switch self {
		case .connectionFailed, .closedUnexpectedly, .server:
			return true
		case .unauthorized, .credentialUnavailable, .protocolViolation, .audioUnavailable:
			return false
		}
	}

	public var errorDescription: String? {
		switch self {
		case .unauthorized:
			return "the server rejected the credential, including after a refresh"
		case .credentialUnavailable(let why):
			return "could not obtain a credential: \(why)"
		case .connectionFailed(let why):
			return "could not connect: \(why)"
		case .closedUnexpectedly(let code, let reason):
			return "the connection closed unexpectedly (code \(code)\(reason.isEmpty ? "" : ": \(reason)"))"
		case .protocolViolation(let what):
			return "the server sent something unexpected: \(what)"
		case .audioUnavailable(let why):
			return "audio is unavailable: \(why)"
		case .server(let message, let code):
			return code.map { "the server reported an error (\($0)): \(message)" }
				?? "the server reported an error: \(message)"
		}
	}
}
