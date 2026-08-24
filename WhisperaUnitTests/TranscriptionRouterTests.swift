// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaOpenAI

@testable import Whispera

/// The router is the only place engine identity is switched on, so this is the
/// one place that has to stay exhaustive. See WHI-58.
@MainActor
struct TranscriptionRouterTests {
	@Test func everyEngineResolvesToAConformer() {
		for engine in TranscriptionEngine.allCases {
			let transcriber = TranscriptionRouter.transcriber(for: engine)
			#expect(transcriber.engine == engine)
		}
	}

	@Test func theSelectedEngineIsTheOneHandedBack() {
		let router = TranscriptionRouter(engineProvider: { .whisperaStreaming })

		#expect(router.selected == .whisperaStreaming)
		#expect(router.active.engine == .whisperaStreaming)
	}

	@Test func whisperKitResolvesToTheSharedTranscriber() {
		let transcriber = TranscriptionRouter.transcriber(for: .whisperKit)

		#expect(transcriber === WhisperKitTranscriber.shared)
	}

	/// A conformer is reused rather than rebuilt: a streaming engine holds a
	/// live socket and a local one holds a loaded model.
	@Test func resolvingTwiceReturnsTheSameInstance() {
		#expect(
			TranscriptionRouter.transcriber(for: .whisperaStreaming)
				=== TranscriptionRouter.transcriber(for: .whisperaStreaming))
		#expect(
			TranscriptionRouter.transcriber(for: .whisperViaBYOK)
				=== TranscriptionRouter.transcriber(for: .whisperViaBYOK))
		#expect(
			TranscriptionRouter.transcriber(for: .auto) === TranscriptionRouter.transcriber(for: .auto))
	}

	@Test func autoResolvesToTheAutoTranscriber() {
		#expect(TranscriptionRouter.transcriber(for: .auto) === AutoTranscriber.shared)
	}

	/// An absent or unrecognised stored value degrades to the fresh-install
	/// default rather than trapping — a fresh install and a build that shipped an
	/// engine this one no longer does land on the same place.
	///
	/// That place is on-device WhisperKit, not `auto`: `auto` ranks on advertised
	/// delta granularity and so selects nemo-stream, the engine whose delta
	/// contract is broken (WHI-67), which would make a new user's first dictation
	/// the worst version of the product. See WHI-74.
	@Test func anAbsentOrUnknownStoredEngineFallsBackToOnDevice() {
		#expect(TranscriptionEngine.stored(nil) == .whisperKit)
		#expect(TranscriptionEngine.stored("") == .whisperKit)
		#expect(TranscriptionEngine.stored("subscriptionWhisper") == .whisperKit)
		#expect(TranscriptionEngine.stored("whisperKit") == .whisperKit)
		#expect(TranscriptionEngine.stored("auto") == .auto)
		#expect(TranscriptionEngine.fresh == .whisperKit)
	}

	@Test func onlyTheOnDeviceEngineManagesModels() {
		#expect(
			TranscriptionRouter.transcriber(for: .whisperKit).capabilities.contains(.managedModels))
		#expect(
			!TranscriptionRouter.transcriber(for: .whisperaStreaming).capabilities
				.contains(.managedModels))
		#expect(
			!TranscriptionRouter.transcriber(for: .whisperViaBYOK).capabilities
				.contains(.managedModels))
	}

	@Test func uploadOnlyEnginesDoNotClaimStreaming() {
		#expect(TranscriptionRouter.transcriber(for: .whisperKit).capabilities.contains(.streaming))
		#expect(
			TranscriptionRouter.transcriber(for: .whisperaStreaming).capabilities.contains(.streaming))
		#expect(
			!TranscriptionRouter.transcriber(for: .whisperViaBYOK).capabilities.contains(.streaming))
	}

	/// An engine an older build wrote but this one no longer ships must degrade
	/// on-device rather than trap, the same rule `llmMode` follows.
	@Test func anUnknownStoredEngineFallsBackOnDevice() {
		#expect(TranscriptionEngine(rawValue: "subscriptionWhisper") == nil)
		#expect(TranscriptionEngine(rawValue: "") == nil)
		#expect(TranscriptionEngine(rawValue: "whisperKit") == .whisperKit)
	}
}

@MainActor
struct RemoteBatchTranscriberTests {
	@Test func translationIsRefusedRatherThanSilentlyDropped() async {
		let transcriber = RemoteBatchTranscriber()

		await #expect(throws: TranscriptionEngineError.self) {
			try await transcriber.transcribe(
				samples: [0, 0, 0], options: TranscriptionOptions(mode: .translate))
		}
	}

	/// The WAV encoder moved into `WhisperaOpenAI` with the multipart builder —
	/// one place for one wire format (WHI-92, WHI-94). Its own round-trip cases
	/// run in the package's `WAV` check group; what still matters here is that
	/// this conformer hands the encoder the samples it was given.
	@Test func samplesAreEncodedThroughThePackageWavEncoder() {
		let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]

		let payload = AudioPayload.wav(samples: samples)

		#expect(payload.mimetype == "audio/wav")
		#expect(payload.data.count == 44 + samples.count * 2)
		#expect(String(decoding: payload.data[0..<4], as: UTF8.self) == "RIFF")
	}

	/// WHI-92: no absolute provider URL remains in the transcription path. With
	/// nothing configured the engine says so instead of quietly uploading to a
	/// cloud the user never named.
	@Test func nothingConfiguredIsAnErrorRatherThanAPinnedProvider() async {
		// A model but no address: the model check comes first, so this isolates
		// the one thing being asserted — that with no server there is no request.
		let transcriber = RemoteBatchTranscriber(
			entryProvider: { ServerEntry(capability: .speech, urlString: "", model: "whisper-1") })

		#expect(
			transcriber.state
				== .unavailable(RemoteBatchTranscriberError.noServerConfigured.errorDescription ?? ""))
		await #expect(throws: RemoteBatchTranscriberError.noServerConfigured) {
			try await transcriber.transcribe(
				samples: [0, 0, 0], options: TranscriptionOptions(mode: .transcribe))
		}
	}

	/// And with a server configured it uploads there — any OpenAI-compatible
	/// base, not `api.openai.com`.
	@Test func theUploadGoesToTheConfiguredSpeechServer() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"text":"hello"}"#)
		let transcriber = RemoteBatchTranscriber(
			entryProvider: {
				ServerEntry(capability: .speech, urlString: mock.baseURL.absoluteString, model: "whisper-1")
			},
			session: mock.session)

		let text = try await transcriber.transcribe(
			samples: [0, 0.1, -0.1], options: TranscriptionOptions(mode: .transcribe))

		#expect(text == "hello")
		let request = MockURLProtocol.lastRequest(host: mock.host)
		#expect(request?.url?.host == mock.host)
		#expect(request?.url?.path == "/v1/audio/transcriptions")
	}
}
