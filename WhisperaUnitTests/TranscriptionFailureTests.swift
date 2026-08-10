// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Testing
import WhisperaDictation

@testable import Whispera

/// What a user is told when a dictation fails. The rule these pin is that the
/// message names the thing that failed and what to check — a raw
/// "InternalServerError" is the failure mode, not the message.
@MainActor
struct TranscriptionFailureMessageTests {
	private func message(for error: Error) -> String {
		StreamingTranscriber.failure(for: error, destination: "speaches-lan").message
	}

	@Test func everyFailureNamesWhatFailed() {
		let errors: [DictationError] = [
			.unauthorized,
			.credentialUnavailable("keychain locked"),
			.connectionFailed("The Internet connection appears to be offline."),
			.closedUnexpectedly(code: 1006, reason: ""),
			.protocolViolation("not JSON"),
			.audioUnavailable("no input device"),
			.server(message: "InternalServerError: Internal Server Error", code: nil),
		]
		for error in errors {
			let message = self.message(for: error)
			#expect(message.hasSuffix("."), "\(error) produced a fragment: \(message)")
			#expect(message.count > 40, "\(error) produced nothing actionable: \(message)")
		}
	}

	/// The exact failure that made this work necessary: the engine's own words are
	/// not a message a user can do anything with.
	@Test func aServerErrorDoesNotEchoTheEnginesOwnWords() {
		let message = self.message(
			for: DictationError.server(message: "InternalServerError: Internal Server Error", code: nil)
		)
		#expect(!message.contains("InternalServerError"))
		#expect(message.contains("speaches-lan"))
	}

	@Test func anUnreachableServerSaysWhereToLook() {
		let message = self.message(for: DictationError.connectionFailed("offline"))
		#expect(message.contains("speaches-lan"))
		#expect(message.lowercased().contains("network"))
	}

	@Test func aRejectedCredentialPointsAtAccountSettings() {
		#expect(message(for: DictationError.unauthorized).contains("Account settings"))
		#expect(message(for: DictationError.credentialUnavailable("x")).contains("Account settings"))
	}

	@Test func aMissingMicrophonePointsAtPrivacySettings() {
		#expect(message(for: DictationError.audioUnavailable("denied")).contains("Microphone"))
	}

	/// The engine's own capture timeout already reads well; it must survive the
	/// mapping rather than be flattened into the generic fallback.
	@Test func anEngineErrorKeepsItsOwnDescription() {
		let message = self.message(for: StreamingTranscriberError.captureTimedOut)
		#expect(message == StreamingTranscriberError.captureTimedOut.errorDescription)
	}

	@Test func anUnknownErrorStillSaysWhereToLook() {
		struct Boom: Error {}
		#expect(message(for: Boom()).contains("Transcription"))
	}
}

/// Which engines need a server, which is what decides whether the URL fields and
/// the live-transcription default apply.
struct ServerEngineTests {
	@Test func onlySocketEnginesStreamFromAServer() {
		#expect(TranscriptionEngine.whisperaStreaming.streamsFromAServer)
		#expect(TranscriptionEngine.realtimeDirect.streamsFromAServer)
		#expect(!TranscriptionEngine.whisperKit.streamsFromAServer)
		#expect(!TranscriptionEngine.whisperViaBYOK.streamsFromAServer)
	}

	/// Every engine that streams from a server is one the streaming conformer
	/// handles, so the two never drift apart.
	@MainActor
	@Test func everyServerEngineResolvesToTheStreamingConformer() {
		for engine in TranscriptionEngine.allCases where engine.streamsFromAServer {
			#expect(TranscriptionRouter.transcriber(for: engine) is StreamingTranscriber)
		}
	}
}
