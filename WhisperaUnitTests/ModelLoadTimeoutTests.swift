import AppKit
import Foundation
import Testing

@testable import Whispera

@MainActor
struct InFlightModelLoadTimeoutTests {
	@Test func aHungLoadFailsWithAMessage() async {
		let clock = ContinuousClock()
		let start = clock.now
		await #expect(throws: WhisperKitError.self) {
			try await WhisperKitTranscriber.waitWhileLoading(
				timeoutSeconds: 0.2, pollNanoseconds: 20_000_000, modelName: "Large v3"
			) { true }
		}
		#expect(clock.now - start < .seconds(2))
		#expect(WhisperKitError.modelLoadTimedOut("Large v3").errorDescription?.contains("Large v3") == true)
	}

	@Test func aLoadThatFinishesReturns() async throws {
		var polls = 0
		try await WhisperKitTranscriber.waitWhileLoading(
			timeoutSeconds: 5, pollNanoseconds: 10_000_000, modelName: nil
		) {
			polls += 1
			return polls < 3
		}
		#expect(polls == 3)
	}
}
