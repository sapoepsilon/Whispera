import Foundation
import Testing

@testable import Whispera

struct MediaPauseSessionTests {
	let start = Date(timeIntervalSinceReferenceDate: 0)

	@Test func resumesInsideTheGap() {
		let session = MediaPauseSession(pausedPIDs: [42], startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(30)))
	}

	@Test func gapBoundaryStillResumes() {
		let session = MediaPauseSession(pausedPIDs: [42], startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap)))
	}

	@Test func skipsResumeBeyondTheGap() {
		let session = MediaPauseSession(pausedPIDs: [42], startedAt: start)
		#expect(!session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)))
	}
}

/// Stands in for the two hardware-facing seams — the CoreAudio per-process
/// activity read and the media-key post.
///
/// The rendering-pid reads are scripted: each call pops the next set, and the
/// last one repeats once the script runs out, so a test states exactly what the
/// world looks like at the baseline read and at each poll after a key press.
/// File-scoped so it stays nonisolated: the coordinator's `@Sendable` closures
/// call it off the main actor.
private final class MediaKeyRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var _keyPresses = 0
	private var _script: [Set<pid_t>]
	private var _last: Set<pid_t> = []
	private var _now = Date(timeIntervalSinceReferenceDate: 0)

	init(script: [Set<pid_t>]) {
		_script = script
	}

	var keyPresses: Int { lock.withLock { _keyPresses } }
	var now: Date {
		get { lock.withLock { _now } }
		set { lock.withLock { _now = newValue } }
	}

	func sendKey() { lock.withLock { _keyPresses += 1 } }

	func nextPIDs() -> Set<pid_t> {
		lock.withLock {
			if !_script.isEmpty { _last = _script.removeFirst() }
			return _last
		}
	}
}

@MainActor
struct MediaPlaybackCoordinatorFlowTests {

	/// A window short enough to keep the suite fast but wide enough for several
	/// scripted polls.
	private static let pollInterval = 0.001
	private static let verifyWindow = 0.005

	private func makeCoordinator(
		enabled: Bool = true,
		script: [Set<pid_t>] = []
	) -> (MediaPlaybackCoordinator, MediaKeyRecorder) {
		let recorder = MediaKeyRecorder(script: script)
		let coordinator = MediaPlaybackCoordinator(
			isEnabled: { enabled },
			renderingPIDs: { recorder.nextPIDs() },
			sendPlayPauseKey: { recorder.sendKey() },
			pollInterval: Self.pollInterval,
			verifyWindow: Self.verifyWindow,
			now: { recorder.now }
		)
		return (coordinator, recorder)
	}

	/// Something disappeared from the rendering set right after our key: we paused
	/// it, and a later resume has a session to act on.
	@Test func pauseWithDisappearanceRecordsASession() async {
		// baseline [42] -> poll [] (paused) | resume baseline [] -> poll [42] (back)
		let (coordinator, recorder) = makeCoordinator(script: [[42], [], [], [42]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		#expect(recorder.keyPresses == 1)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}

	/// Nothing was playing, so the toggle *started* something. The undo press is
	/// the whole point of watching the effect instead of predicting it, and no
	/// session may survive it.
	@Test func pauseWithAppearanceUndoesItselfAndRecordsNothing() async {
		let (coordinator, recorder) = makeCoordinator(script: [[], [99]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		#expect(recorder.keyPresses == 2)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}

	/// Constant renderers such as Parsec sit in both sets and cancel out; an
	/// unchanged world means the key reached nothing worth undoing or resuming.
	@Test func pauseWithNoChangeSendsNothingFurther() async {
		let (coordinator, recorder) = makeCoordinator(script: [[7], [7]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		#expect(recorder.keyPresses == 1)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// Playback running again is playback the user restarted; the toggle would
	/// stop it.
	@Test func resumeSkipsPlaybackTheUserRestarted() async {
		let (coordinator, recorder) = makeCoordinator(script: [[42], [], [42]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// A resume that wakes a *different* app is the same mistake as a pause that
	/// starts one, and gets the same undo.
	@Test func resumeThatStartsADifferentAppUndoesItself() async {
		let (coordinator, recorder) = makeCoordinator(script: [[42], [], [], [99]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 3)
	}

	@Test func staleSessionIsNotResumed() async {
		let (coordinator, recorder) = makeCoordinator(script: [[42], [], [], [42]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		recorder.now = recorder.now.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	@Test func disabledSettingSendsNothing() async {
		let (coordinator, recorder) = makeCoordinator(enabled: false, script: [[42], []])

		await coordinator.pauseBeforeDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	@Test func resumeWithoutAPauseSendsNothing() async {
		let (coordinator, recorder) = makeCoordinator(script: [[42]])

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	@Test func secondResumeForOneDictationIsANoOp() async {
		let (coordinator, recorder) = makeCoordinator(script: [[42], [], [], [42]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}
}
