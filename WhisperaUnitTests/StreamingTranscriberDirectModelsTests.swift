// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

@testable import Whispera

/// Direct mode has no backend registry to ask what it can run, so `models()`
/// asks the engine itself via its OpenAI-compatible `/models` endpoint. See
/// WHI-58, PASTE-MODEL-RESULT.md.
@MainActor
struct StreamingTranscriberDirectModelsTests {
	private func directTranscriber(mock: MockURLProtocol.Mock) -> StreamingTranscriber {
		StreamingTranscriber(
			baseURLProvider: { mock.baseURL },
			directProvider: { true },
			urlSession: mock.session)
	}

	@Test func onlyAutomaticSpeechRecognitionModelsAreReturned() async throws {
		let mock = MockURLProtocol.make(
			status: 200,
			json: #"""
				{"data": [
					{"id": "Systran/faster-distil-whisper-large-v3", "task": "automatic-speech-recognition"},
					{"id": "some-embedding-model", "task": "embeddings"},
					{"id": "Systran/faster-whisper-small", "task": "automatic-speech-recognition"}
				]}
				"""#)
		let transcriber = directTranscriber(mock: mock)

		let models = try await transcriber.models()

		#expect(models.map(\.id) == ["Systran/faster-distil-whisper-large-v3", "Systran/faster-whisper-small"])
	}

	@Test func requestGoesToTheEnginesModelsEndpoint() async throws {
		let mock = MockURLProtocol.make(
			status: 200,
			json: #"{"data": [{"id": "m", "task": "automatic-speech-recognition"}]}"#)
		let transcriber = directTranscriber(mock: mock)

		_ = try await transcriber.models()

		let request = MockURLProtocol.lastRequest(host: mock.host)
		#expect(request?.url?.path == "/models")
	}

	@Test func anUnreachableEngineFailsLoudlyRatherThanReturningNoModels() async {
		let mock = MockURLProtocol.make(status: 500, json: "")
		let transcriber = directTranscriber(mock: mock)

		await #expect(throws: StreamingTranscriberError.self) {
			_ = try await transcriber.models()
		}
	}

	@Test func unparsableJSONIsReportedAsUnreachableRatherThanCrashing() async {
		let mock = MockURLProtocol.make(status: 200, json: "not json")
		let transcriber = directTranscriber(mock: mock)

		await #expect(throws: StreamingTranscriberError.self) {
			_ = try await transcriber.models()
		}
	}

	/// An engine that answers but serves nothing transcription can use (an
	/// LLM-only host, say) is a distinct failure from one that cannot be
	/// reached at all — worth its own message rather than an empty list.
	@Test func anEngineWithNoASRModelsThrowsRatherThanReturningAnEmptyList() async {
		let mock = MockURLProtocol.make(
			status: 200,
			json: #"{"data": [{"id": "chat-model", "task": "text-generation"}]}"#)
		let transcriber = directTranscriber(mock: mock)

		await #expect(throws: StreamingTranscriberError.self) {
			_ = try await transcriber.models()
		}
	}
}
