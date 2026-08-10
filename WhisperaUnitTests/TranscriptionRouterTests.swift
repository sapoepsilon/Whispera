// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

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

	@Test func samplesAreWrappedInAReadableWavContainer() {
		let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]

		let wav = RemoteBatchTranscriber.wav(from: samples, sampleRate: 16000)

		#expect(wav.count == 44 + samples.count * 2)
		#expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
		#expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
		#expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
		#expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")

		let sampleRate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
		#expect(UInt32(littleEndian: sampleRate) == 16000)

		let dataBytes = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
		#expect(UInt32(littleEndian: dataBytes) == UInt32(samples.count * 2))
	}

	@Test func fullScaleSamplesClipRatherThanWrap() {
		let wav = RemoteBatchTranscriber.wav(from: [1.0, -1.0, 2.0], sampleRate: 16000)
		let pcm = wav[44...]

		let first = pcm[pcm.startIndex..<pcm.startIndex + 2].withUnsafeBytes {
			Int16(littleEndian: $0.loadUnaligned(as: Int16.self))
		}
		let third = pcm[pcm.startIndex + 4..<pcm.startIndex + 6].withUnsafeBytes {
			Int16(littleEndian: $0.loadUnaligned(as: Int16.self))
		}

		#expect(first == Int16.max)
		#expect(third == Int16.max)
	}
}
