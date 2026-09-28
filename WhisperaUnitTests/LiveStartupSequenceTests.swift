import Foundation
import Testing

@testable import Whispera

@MainActor
struct LiveStartupSequenceTests {
	/// Preparing the custom-word prompt can load a prewarmed model's weights, which took 41 s for
	/// large-v3 turbo on a busy Mac. Every word said before the microphone opened was lost.
	@Test func microphoneOpensBeforeThePromptIsPrepared() async throws {
		var steps: [String] = []
		try await LiveStartupSequence.run(
			openMicrophone: { steps.append("microphone") },
			preparePrompt: { steps.append("prompt") },
			isCurrent: { true },
			startDecoding: { steps.append("decoding") })
		#expect(steps == ["microphone", "prompt", "decoding"])
	}

	@Test func microphoneCapturesWhileThePromptIsPrepared() async throws {
		var microphoneOpen = false
		var openDuringPrompt = false
		try await LiveStartupSequence.run(
			openMicrophone: { microphoneOpen = true },
			preparePrompt: { openDuringPrompt = microphoneOpen },
			isCurrent: { true },
			startDecoding: {})
		#expect(openDuringPrompt)
	}

	@Test func sessionStoppedDuringPromptPreparationStartsNoDecoding() async {
		var current = true
		var decoding = false
		await #expect(throws: CancellationError.self) {
			try await LiveStartupSequence.run(
				openMicrophone: {},
				preparePrompt: { current = false },
				isCurrent: { current },
				startDecoding: { decoding = true })
		}
		#expect(!decoding)
	}

	@Test func microphoneFailureSkipsThePrompt() async {
		struct MicrophoneFailed: Error {}
		var prompt = false
		await #expect(throws: MicrophoneFailed.self) {
			try await LiveStartupSequence.run(
				openMicrophone: { throw MicrophoneFailed() },
				preparePrompt: { prompt = true },
				isCurrent: { true },
				startDecoding: {})
		}
		#expect(!prompt)
	}
}
