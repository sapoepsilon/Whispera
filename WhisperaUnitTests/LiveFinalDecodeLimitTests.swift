import Foundation
import Testing
import WhisperKit

@testable import Whispera

@MainActor
private struct FixedClip: LiveAudioSource {
	let samples: [Float]
	var sampleCount: Int { samples.count }
	func samples(from start: Int) -> [Float] { Array(samples[min(start, samples.count)...]) }
}

@MainActor
struct LiveFinalDecodeLimitTests {
	private func settings() -> LivePassSettings {
		LivePassSettings(
			base: DecodingOptions(), voiceActivity: VoiceActivitySettings(enabled: false), promptWords: [])
	}

	/// A dictation stopped while a slow model load held every pass back has only the final decode;
	/// on a busy Mac large-v3 turbo needed more than 8 s for 22 s of it, and all of it was dropped.
	@Test func decodeOfAWindowNoPassDecodedGetsAsLongAsTheAudio() async {
		let pass = LiveDictationPass()
		let clip = FixedClip(samples: [Float](repeating: 0, count: 2 * WhisperKit.sampleRate))
		let typed = await pass.finish(
			audio: clip, settings: settings(),
			decode: { _, _ in
				try await Task.sleep(for: .milliseconds(400))
				return LiveDecodeOutput(segments: [LiveSegment(text: "Hello there.", start: 0, end: 1.8)], language: "en")
			},
			timeLimit: .milliseconds(100))
		#expect(typed == "Hello there.")
	}

	@Test func decodeLongerThanTheAudioStillGivesUp() async {
		let pass = LiveDictationPass()
		let clip = FixedClip(samples: [Float](repeating: 0, count: WhisperKit.sampleRate / 10))
		let typed = await pass.finish(
			audio: clip, settings: settings(),
			decode: { _, _ in
				try await Task.sleep(for: .seconds(5))
				return LiveDecodeOutput(segments: [LiveSegment(text: "Late.", start: 0, end: 0.1)], language: "en")
			},
			timeLimit: .milliseconds(100))
		#expect(typed.isEmpty)
	}

	@Test func limitIsTheLongerOfTheBaseAndTheWindow() {
		let rate = WhisperKit.sampleRate
		#expect(LiveDictationPass.finalDecodeLimit(.seconds(8), windowSamples: 22 * rate) == .seconds(22))
		#expect(LiveDictationPass.finalDecodeLimit(.seconds(8), windowSamples: 3 * rate) == .seconds(8))
	}
}
