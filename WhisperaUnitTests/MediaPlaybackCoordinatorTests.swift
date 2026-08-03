import Foundation
import Testing

@testable import Whispera

struct MediaPauseSessionTests {
	let start = Date(timeIntervalSinceReferenceDate: 0)

	@Test func resumesInsideTheGap() {
		let session = MediaPauseSession(startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(30)))
	}

	@Test func gapBoundaryStillResumes() {
		let session = MediaPauseSession(startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap)))
	}

	@Test func skipsResumeBeyondTheGap() {
		let session = MediaPauseSession(startedAt: start)
		#expect(!session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)))
	}
}

/// Stands in for the two hardware-facing seams — the CoreAudio activity read and
/// the media-key post. File-scoped so it stays nonisolated: the coordinator's
/// `@Sendable` closures call it off the main actor.
private final class MediaKeyRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var _keyPresses = 0
	private var _outputRunning = true
	private var _now = Date(timeIntervalSinceReferenceDate: 0)

	var keyPresses: Int { lock.withLock { _keyPresses } }
	var outputRunning: Bool {
		get { lock.withLock { _outputRunning } }
		set { lock.withLock { _outputRunning = newValue } }
	}
	var now: Date {
		get { lock.withLock { _now } }
		set { lock.withLock { _now = newValue } }
	}

	func sendKey() { lock.withLock { _keyPresses += 1 } }
}

@MainActor
struct MediaPlaybackCoordinatorFlowTests {

	private func makeCoordinator(
		enabled: Bool = true,
		outputRunning: Bool = true
	) -> (MediaPlaybackCoordinator, MediaKeyRecorder) {
		let recorder = MediaKeyRecorder()
		recorder.outputRunning = outputRunning
		let coordinator = MediaPlaybackCoordinator(
			isEnabled: { enabled },
			isOutputRunning: { recorder.outputRunning },
			sendPlayPauseKey: { recorder.sendKey() },
			resumeSettleSeconds: 0,
			now: { recorder.now }
		)
		return (coordinator, recorder)
	}

	@Test func pauseSendsTheKeyWhenSomethingIsPlaying() async {
		let (coordinator, recorder) = makeCoordinator()

		await coordinator.pauseBeforeDictation()

		#expect(recorder.keyPresses == 1)
	}

	/// The key is a toggle: firing it against a silent system would start
	/// playback the user never asked for.
	@Test func pauseSendsNothingWhenNothingIsPlaying() async {
		let (coordinator, recorder) = makeCoordinator(outputRunning: false)

		await coordinator.pauseBeforeDictation()

		#expect(recorder.keyPresses == 0)
	}

	@Test func disabledSettingSendsNothing() async {
		let (coordinator, recorder) = makeCoordinator(enabled: false)

		await coordinator.pauseBeforeDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	@Test func resumeSendsTheKeyOncePlaybackHasStopped() async {
		let (coordinator, recorder) = makeCoordinator()

		await coordinator.pauseBeforeDictation()
		recorder.outputRunning = false
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}

	/// Playback running again means the user restarted it themselves; the toggle
	/// would stop it.
	@Test func resumeSkipsPlaybackTheUserRestarted() async {
		let (coordinator, recorder) = makeCoordinator()

		await coordinator.pauseBeforeDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	@Test func resumeWithoutAPauseSendsNothing() async {
		let (coordinator, recorder) = makeCoordinator(outputRunning: false)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	/// A pause that never fired leaves nothing to put back, so the stop paths that
	/// all call resume must not start idle media.
	@Test func skippedPauseMeansNoResume() async {
		let (coordinator, recorder) = makeCoordinator(outputRunning: false)

		await coordinator.pauseBeforeDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	@Test func secondResumeForOneDictationIsANoOp() async {
		let (coordinator, recorder) = makeCoordinator()

		await coordinator.pauseBeforeDictation()
		recorder.outputRunning = false
		coordinator.resumeAfterDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}

	@Test func staleSessionIsNotResumed() async {
		let (coordinator, recorder) = makeCoordinator()

		await coordinator.pauseBeforeDictation()
		recorder.outputRunning = false
		recorder.now = recorder.now.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}
}
