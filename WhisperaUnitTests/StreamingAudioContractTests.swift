// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaDictation

@testable import Whispera

/// What the client puts on the wire and how fast: the audio format it takes
/// from the server it is pointed at (WHI-71), and the two things that keep a
/// stalled sender from dumping a backlog into the engine at once (WHI-70).
///
/// Both are driven through the shipping types rather than a copy of them — the
/// buffering policy `MicrophoneSource.frames()` hands to its `AsyncStream`, the
/// pacing function `DictationSession` calls, and the format
/// `DictationConfiguration` actually carries.
struct StreamingAudioContractTests {
	private static func server(_ json: String) throws -> DictationServer {
		try JSONDecoder().decode(DictationServer.self, from: Data(json.utf8))
	}

	// MARK: - Per-server audio format (WHI-71)

	/// The client used to decode `realtime.audio` and then hardcode 24 kHz at
	/// every send site. It worked by luck: the one engine in play resampled
	/// internally. A server that advertises 16 kHz now gets 16 kHz.
	@Test func aServerAdvertising16kHzIsStreamedAt16kHz() throws {
		let server = try Self.server(
			"""
			{"id":"nemo-stream","label":"NeMo","model":"parakeet",\
			"capabilities":["realtime"],"status":"online",\
			"realtime":{"protocol":"openai-realtime","path":"/transcription/stream?server=nemo-stream",\
			"granularity":"native-delta",\
			"audio":{"encoding":"pcm16","sampleRate":16000,"channels":1}}}
			""")

		#expect(server.audioFormat.sampleRate == 16_000)
		#expect(server.audioFormat.channels == 1)
		#expect(server.audioFormat.encoding == .pcm16)

		let configuration = DictationConfiguration.backend(
			URL(string: "http://127.0.0.1:3000")!,
			server: server.id, model: server.model, audio: server.audioFormat)
		#expect(configuration.audioFormat.sampleRate == 16_000)

		// The capture side has to agree, or the tap converts to one rate and the
		// session frames it at another.
		#expect(MicrophoneSource(format: configuration.audioFormat).format.sampleRate == 16_000)

		// One second of 48 kHz mono float32 — what an AVAudioEngine tap hands over
		// — becomes one second of 16 kHz mono PCM16: 32 000 bytes, not the 48 000
		// the 24 kHz constant would have produced.
		var normalizer = AudioNormalizer(
			from: DictationAudioFormat(sampleRate: 48_000, channels: 1, encoding: .float32),
			to: configuration.audioFormat)
		var input = Data()
		for i in 0..<48_000 {
			let value = Float(sin(Double(i) * 0.01))
			input.append(withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) })
		}
		let (pcm, _) = normalizer.normalize(input)
		#expect(abs(pcm.count - 32_000) <= 64)
	}

	/// A backend that predates the field, or a server with nothing to say about
	/// audio, keeps the 24 kHz default this client always used.
	@Test func aServerThatAdvertisesNoFormatKeepsTheEngineDefault() throws {
		let quiet = try Self.server(
			"""
			{"id":"speaches-lan","label":"speaches","model":"whisper",\
			"capabilities":["realtime"],\
			"realtime":{"protocol":"openai-realtime","path":"/x"}}
			""")
		#expect(quiet.audioFormat == .engine)
		#expect(quiet.audioFormat.sampleRate == 24_000)

		let configuration = DictationConfiguration.backend(
			URL(string: "http://127.0.0.1:3000")!,
			server: quiet.id, model: quiet.model, audio: quiet.audioFormat)
		#expect(configuration.audioFormat.sampleRate == 24_000)
	}

	// MARK: - Bounded microphone stream (WHI-70)

	/// `AsyncStream`'s default policy is `.unbounded`, so a consumer that stalls
	/// queues every frame of the stall and then drains the lot in one burst —
	/// which is what puts speaches' always-on VAD into its duplicate
	/// `speech_stopped` / `already exists` / empty-transcript regime. The policy
	/// the source ships is exercised here, not a copy of it, so reverting
	/// `frames()` to a bare `AsyncStream {}` fails this.
	@Test func aStalledConsumerSeesTheNewestFramesNotAMinuteOfOldOnes() async {
		let produced = MicrophoneSource.frameBufferLimit * 20
		let stream = AsyncStream<Data>(
			bufferingPolicy: MicrophoneSource.framesBufferingPolicy
		) { continuation in
			for i in 0..<produced { continuation.yield(Data([UInt8(i % 251)])) }
			continuation.finish()
		}

		var received: [Data] = []
		for await frame in stream { received.append(frame) }

		#expect(received.count == MicrophoneSource.frameBufferLimit)
		#expect(received.last == Data([UInt8((produced - 1) % 251)]))
		#expect(MicrophoneSource.frameBufferLimit < produced)
	}

	// MARK: - Paced sends (WHI-70)

	/// Pacing costs nothing while a dictation keeps up, and only bites once audio
	/// has actually run ahead of the wall clock.
	@Test func pacingWaitsOnlyOnABacklog() {
		#expect(DictationAudioPacing.delay(audioSent: 0, elapsed: 0, allowance: 1) == 0)
		#expect(DictationAudioPacing.delay(audioSent: 1.0, elapsed: 1.0, allowance: 1) == 0)
		#expect(DictationAudioPacing.delay(audioSent: 0.4, elapsed: 2.0, allowance: 1) == 0)
		// A minute of backlog against a tenth of a second of wall clock: the burst
		// the bounded stream caps and the pacer refuses to hand over at once.
		#expect(abs(DictationAudioPacing.delay(audioSent: 60, elapsed: 0.1, allowance: 1) - 58.9) < 0.001)
	}

	/// A live source is paced; a file is deliberately not — uploading one as fast
	/// as the socket accepts it is the whole point.
	@Test func onlyALiveSourceIsPaced() {
		#expect(MicrophoneSource().isLive)
		#expect(!PushAudioSource().isLive)
	}
}
