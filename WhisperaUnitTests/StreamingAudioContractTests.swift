// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaDictation

@testable import Whispera

/// How fast the client puts audio on the wire: the two things that keep a
/// stalled sender from dumping a backlog into the engine at once (WHI-70).
///
/// Both are driven through the shipping types rather than a copy of them — the
/// buffering policy `MicrophoneSource.frames()` hands to its `AsyncStream` and
/// the pacing function `DictationSession` calls.
struct StreamingAudioContractTests {
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
