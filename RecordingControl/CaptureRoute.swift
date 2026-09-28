import Foundation

/// The capture path a new dictation takes, derived from the same settings AudioManager
/// uses to start one. Settings rows use it to say when an option has no effect.
enum CaptureRoute: Equatable, Sendable {
	/// Live Transcription Mode: WhisperKit's own recorder feeds the live transcriber.
	case live
	/// Record-then-transcribe through Whispera's AVAudioEngine tap.
	case stream
	/// Record-then-transcribe through an AVAudioRecorder file.
	case file

	/// Parakeet cannot stream text back, so it records through the stream or file path even
	/// with Live Transcription Mode on.
	static func resolve(
		liveTranscriptionEnabled: Bool, modelSupportsLive: Bool, useStreamingTranscription: Bool
	) -> CaptureRoute {
		if liveTranscriptionEnabled && modelSupportsLive { return .live }
		return useStreamingTranscription ? .stream : .file
	}

	/// Only the engine tap can stay open between recordings.
	var canKeepMicrophoneOpen: Bool { self == .stream }
}

extension MicStreamPolicy {
	/// Why this policy does nothing on the given route, or nil when it applies.
	func inactiveReason(on route: CaptureRoute) -> String? {
		guard self != .onDemand, !route.canKeepMicrophoneOpen else { return nil }
		switch route {
		case .live:
			return String(
				localized:
					"No effect in Live Transcription Mode: WhisperKit opens the microphone for each recording. Turn Live Transcription Mode off to use this."
			)
		case .file:
			return String(
				localized:
					"No effect with streaming transcription off: each recording opens the microphone to write a file.")
		case .stream:
			return nil
		}
	}

	func settingsDescription(on route: CaptureRoute) -> String {
		inactiveReason(on: route) ?? summary
	}
}
