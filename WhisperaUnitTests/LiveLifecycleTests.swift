import Foundation
import Testing

@testable import Whispera

struct LiveSessionGateTests {
	@Test func stoppedSessionIsStale() {
		var gate = LiveSessionGate()
		let first = gate.begin()
		#expect(gate.isCurrent(first))
		gate.end()
		#expect(!gate.isCurrent(first), "Startup resuming after stop must not open the mic")
		#expect(!gate.isActive)
	}

	@Test func restartedSessionInvalidatesThePreviousOne() {
		var gate = LiveSessionGate()
		let first = gate.begin()
		gate.end()
		let second = gate.begin()
		#expect(!gate.isCurrent(first), "A decode pass from the old session must not type into the new one")
		#expect(gate.isCurrent(second))
	}

	@Test func beginWithoutStopStillSupersedes() {
		var gate = LiveSessionGate()
		let first = gate.begin()
		let second = gate.begin()
		#expect(!gate.isCurrent(first))
		#expect(gate.isCurrent(second))
	}

	@Test func nothingIsCurrentBeforeTheFirstSession() {
		let gate = LiveSessionGate()
		#expect(!gate.isCurrent(0))
	}
}

struct DeferredEngineReleaseTests {
	@Test func idleEngineIsReleasedAtOnce() {
		var release = DeferredEngineRelease<String>()
		let released = release.release("a", activeUses: 0)
		#expect(released == "a")
		#expect(release.parked.isEmpty)
	}

	@Test func engineInUseIsParkedUntilTheLastHoldEnds() {
		var release = DeferredEngineRelease<String>()
		let released = release.release("a", activeUses: 2)
		#expect(released == nil)
		let whileHeld = release.drain(activeUses: 1)
		#expect(whileHeld.isEmpty)
		#expect(release.parked == ["a"])
		let afterLastHold = release.drain(activeUses: 0)
		#expect(afterLastHold == ["a"])
		#expect(release.parked.isEmpty)
		let again = release.drain(activeUses: 0)
		#expect(again.isEmpty)
	}
}

struct IdleUnloadRetryPolicyTests {
	@Test func retriesAreBounded() {
		var policy = IdleUnloadRetryPolicy()
		var retries = 0
		while retries <= IdleUnloadRetryPolicy.maxAttempts, policy.shouldRetry() {
			retries += 1
		}
		#expect(retries == IdleUnloadRetryPolicy.maxAttempts)
		let another = policy.shouldRetry()
		#expect(!another)
	}

	@Test func resetAllowsAFreshRoundOfRetries() {
		var policy = IdleUnloadRetryPolicy()
		while policy.shouldRetry() {}
		policy.reset()
		let retry = policy.shouldRetry()
		#expect(retry)
	}
}

struct CaptureStopRoutingTests {
	@Test func stopUsesThePathTheSessionStartedOn() {
		#expect(CapturePath.toStop(active: .file, mode: .text) == .file)
		#expect(CapturePath.toStop(active: .stream, mode: .text) == .stream)
		#expect(CapturePath.toStop(active: .live, mode: .liveTranscription) == .live)
	}

	@Test func stopWithoutACaptureOnlyResetsState() {
		#expect(CapturePath.toStop(active: nil, mode: .liveTranscription) == .live)
		#expect(CapturePath.toStop(active: nil, mode: .text) == .stream)
	}
}

struct SampleRingTests {
	@Test func keepsEverythingBelowCapacity() {
		var ring = SampleRing(capacity: 5)
		ring.append(contentsOf: [1, 2])
		ring.append(contentsOf: [3])
		#expect(ring.ordered() == [1, 2, 3])
	}

	@Test func overwritesTheOldestOnceFull() {
		var ring = SampleRing(capacity: 4)
		ring.append(contentsOf: [1, 2, 3])
		ring.append(contentsOf: [4, 5, 6])
		#expect(ring.ordered() == [3, 4, 5, 6])
		ring.append(contentsOf: [7])
		#expect(ring.ordered() == [4, 5, 6, 7])
		ring.append(contentsOf: [8, 9, 10])
		#expect(ring.ordered() == [7, 8, 9, 10])
		#expect(ring.count == 4)
	}

	@Test func chunkLargerThanCapacityKeepsItsTail() {
		var ring = SampleRing(capacity: 3)
		ring.append(contentsOf: [1])
		ring.append(contentsOf: [2, 3, 4, 5, 6])
		#expect(ring.ordered() == [4, 5, 6])
	}

	@Test func removeAllStartsOver() {
		var ring = SampleRing(capacity: 3)
		ring.append(contentsOf: [1, 2, 3, 4])
		ring.removeAll()
		ring.append(contentsOf: [9])
		#expect(ring.ordered() == [9])
	}

	@Test func matchesANaiveWindowOverManyAppends() {
		var ring = SampleRing(capacity: 37)
		var reference: [Float] = []
		var next: Float = 0
		for size in [1, 5, 36, 2, 37, 0, 13, 40, 7, 7, 7, 29, 3] {
			let chunk = (0..<size).map { _ in
				next += 1
				return next
			}
			ring.append(contentsOf: chunk)
			reference = Array((reference + chunk).suffix(37))
			#expect(ring.ordered() == reference)
		}
	}

	@Test func captureBufferPastTheCapIsCheapPerAppend() {
		let cap = 16000 * 60
		let buffer = StreamCaptureBuffer(maxSamples: cap)
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		let chunk = [Float](repeating: 0.5, count: 1024)
		for _ in 0..<(cap / chunk.count + 1) {
			buffer.append(chunk)
		}
		// Past the cap each append used to memmove the whole window; a ring only writes the chunk
		let clock = ContinuousClock()
		let elapsed = clock.measure {
			for _ in 0..<2000 {
				buffer.append(chunk)
			}
		}
		#expect(elapsed < .seconds(1), "2000 appends past the cap took \(elapsed)")
		#expect(buffer.finishCapture().count == cap)
	}
}

struct ShortcutSourceDeduplicationTests {
	private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

	@Test func quickSecondPressFromTheSameSourceStops() {
		var m = ActivationStateMachine(mode: .toggle, holdThreshold: 0.3)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false, source: .eventMonitor) == .start)
		#expect(
			m.keyDown(
				at: t0.addingTimeInterval(0.15), isRepeat: false, isSessionActive: true, source: .eventMonitor)
				== .stop)
	}

	@Test func samePressSeenByTheSecureInputFallbackIsIgnored() {
		var m = ActivationStateMachine(mode: .toggle, holdThreshold: 0.3)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false, source: .eventMonitor) == .start)
		#expect(
			m.keyDown(
				at: t0.addingTimeInterval(0.05), isRepeat: false, isSessionActive: true,
				source: .secureInputFallback)
				== .none)
		#expect(
			m.keyDown(
				at: t0.addingTimeInterval(1), isRepeat: false, isSessionActive: true,
				source: .secureInputFallback)
				== .stop)
	}
}

/// A failed load used to leave `isModelLoading` set, which blocked idle unload for the rest of the run.
@MainActor
@Suite(.serialized)
struct ModelLoadFailureTests {
	@Test(.timeLimit(.minutes(5)))
	func failedLoadClearsTheLoadingState() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let deadline = Date().addingTimeInterval(180)
		while !(transcriber.isInitialized && !transcriber.isModelLoading), Date() < deadline {
			try await Task.sleep(nanoseconds: 250_000_000)
		}
		try #require(transcriber.isInitialized, "Transcriber never finished initializing")
		let loadedBefore = transcriber.whisperKit
		let modelBefore = transcriber.currentModel

		await #expect(throws: (any Error).self) {
			try await transcriber.loadModel(CustomWhisperModel.idPrefix + "missing-\(UUID().uuidString)")
		}

		#expect(!transcriber.isModelLoading)
		#expect(transcriber.loadProgress == 0)
		#expect(!transcriber.idleUnloadBlockers.contains("model loading"))
		#expect(transcriber.whisperKit === loadedBefore, "A failed load must keep the working model")
		#expect(transcriber.currentModel == modelBefore)
	}
}
