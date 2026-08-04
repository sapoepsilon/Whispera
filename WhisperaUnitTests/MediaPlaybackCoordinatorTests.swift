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

	/// Windows short enough to keep the suite fast, keeping the shipped shape:
	/// a tight appearance check and a lazier, longer disappearance check.
	private static let fastPollInterval = 0.001
	private static let fastWindow = 0.003
	private static let slowPollInterval = 0.002
	private static let slowWindow = 0.010
	/// How many rendering-pid reads the appearance check consumes when it never
	/// matches — scripts have to cover them before the disappearance can show up.
	private static let fastPolls = 3

	/// A process that renders output the whole time, the way Parsec and Final Cut
	/// Pro do. It sits in every sample, so it moves no delta and never earns a
	/// toggle.
	private static let constantRenderer: pid_t = 7

	/// Builds a coordinator whose observer is stepped by hand: `observeInterval: 0`
	/// keeps the background loop from racing the scripted seam, so every sample a
	/// test reads is one the test wrote.
	private func makeUnobservedCoordinator(
		enabled: Bool = true,
		script: [Set<pid_t>] = [],
		slowPollInterval: Double = MediaPlaybackCoordinatorFlowTests.slowPollInterval,
		slowWindow: Double = MediaPlaybackCoordinatorFlowTests.slowWindow
	) -> (MediaPlaybackCoordinator, MediaKeyRecorder) {
		let recorder = MediaKeyRecorder(script: script)
		let coordinator = MediaPlaybackCoordinator(
			isEnabled: { enabled },
			renderingPIDs: { recorder.nextPIDs() },
			processIsAlive: { _ in true },
			sendPlayPauseKey: { recorder.sendKey() },
			fastPollInterval: Self.fastPollInterval,
			fastWindow: Self.fastWindow,
			slowPollInterval: slowPollInterval,
			slowWindow: slowWindow,
			observeInterval: 0,
			now: { recorder.now }
		)
		return (coordinator, recorder)
	}

	/// The observation history a press needs: everything rendering, then the
	/// player stops, then it starts again. Ambient pids sit in all three samples
	/// and so stay unproven; `toggled` is seen to move and becomes pressable.
	private func makeCoordinator(
		enabled: Bool = true,
		toggled: Set<pid_t> = [],
		ambient: Set<pid_t> = [MediaPlaybackCoordinatorFlowTests.constantRenderer],
		script: [Set<pid_t>] = [],
		slowPollInterval: Double = MediaPlaybackCoordinatorFlowTests.slowPollInterval,
		slowWindow: Double = MediaPlaybackCoordinatorFlowTests.slowWindow
	) -> (MediaPlaybackCoordinator, MediaKeyRecorder) {
		let history: [Set<pid_t>] = [toggled.union(ambient), ambient, toggled.union(ambient)]
		let (coordinator, recorder) = makeUnobservedCoordinator(
			enabled: enabled,
			script: history + script,
			slowPollInterval: slowPollInterval,
			slowWindow: slowWindow)
		for _ in history { coordinator.observeOnce() }
		return (coordinator, recorder)
	}

	/// Baseline, then the samples the appearance check will read without matching.
	private func holdingThroughFastWindow(_ pids: Set<pid_t>) -> [Set<pid_t>] {
		Array(repeating: pids, count: Self.fastPolls + 1)
	}

	// MARK: - Pause

	/// Nothing has an output stream open, so the toggle could only *start*
	/// playback. The cheapest correct answer is not to press at all.
	@Test func silentSystemIsNeverPressed() async {
		let (coordinator, recorder) = makeCoordinator(ambient: [], script: [[]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
		#expect(coordinator.session == nil)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
	}

	/// A proven player was rendering, so the press was justified — but it woke a
	/// different app instead. The undo press is the whole point of watching the
	/// effect instead of predicting it, and no session may survive it.
	@Test func appearanceInsideTheFastWindowUndoesItself() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: [[42, Self.constantRenderer], [42, Self.constantRenderer, 99]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
		#expect(coordinator.session == nil)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}

	/// The measured falling edge is 2 s, far past the appearance check, so the
	/// disappearance is only visible on the slow cadence — and it is the pids that
	/// actually stopped that get recorded.
	@Test func disappearanceAfterTheFastWindowRecordsASession() async {
		let playing: Set<pid_t> = [42, 43, Self.constantRenderer]
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42, 43],
			script: holdingThroughFastWindow(playing) + [[Self.constantRenderer]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
		#expect(coordinator.session?.pausedPIDs == [42, 43])
	}

	/// Constant renderers sit in both sets and cancel out. Nothing appeared and
	/// nothing stopped, so the press reached an app that ignored it or reached
	/// nothing — pressing again would be a coin flip.
	@Test func neitherEdgeLeavesNoSessionAndNoSecondPress() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42], script: [[42, Self.constantRenderer]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
		#expect(coordinator.session == nil)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// A wrong press is audible, so the appearance check must not be queued behind
	/// the multi-second disappearance window. With the slow cadence set far longer
	/// than the whole test budget, finishing at all proves the fast interval drove
	/// the undo.
	@Test func fastUndoIsNotStarvedByTheSlowWindow() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: [[42, Self.constantRenderer], [42, Self.constantRenderer, 99]],
			slowPollInterval: 0.5,
			slowWindow: 2.0
		)

		let started = Date()
		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		let elapsed = Date().timeIntervalSince(started)

		#expect(recorder.keyPresses == 2)
		#expect(elapsed < 0.25)
	}

	// MARK: - Observer gate

	/// The measurement that forced this gate: `parsecd` reported rendering output
	/// in 100% of samples over 30+ minutes with nothing playing. Presence alone
	/// would press the key on every dictation and blip the user's music.
	@Test func constantRendererLikeParsecNeverEarnsAPress() async {
		let (coordinator, recorder) = makeCoordinator(
			ambient: [Self.constantRenderer], script: [[Self.constantRenderer]])

		#expect(!coordinator.plausiblePlayerIsRendering())

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
		#expect(coordinator.session == nil)
	}

	/// Rendering -> not rendering -> rendering is what a real player looks like,
	/// and it is the only evidence that a press will land on one.
	@Test func pidSeenToStopAndStartAgainEarnsAPress() async {
		let player: pid_t = 42
		let (coordinator, recorder) = makeUnobservedCoordinator(
			script: [[player], [], [player], [player]])

		coordinator.observeOnce()
		#expect(!coordinator.plausiblePlayerIsRendering())
		coordinator.observeOnce()
		coordinator.observeOnce()
		#expect(coordinator.plausiblePlayerIsRendering())

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// The documented limitation, pinned: launch Whispera while music is already
	/// playing and that pid is rendering from the first sample, so we never
	/// witnessed it start and will not press for it. A missed pause is invisible;
	/// a phantom start is not. The user's own next pause marks it.
	@Test func pidRenderingSinceTheFirstSampleIsNeverPressedFor() async {
		let playingAtLaunch: pid_t = 55
		let (coordinator, recorder) = makeUnobservedCoordinator(
			script: [[playingAtLaunch]])

		for _ in 0..<5 { coordinator.observeOnce() }
		#expect(!coordinator.plausiblePlayerIsRendering())

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
		#expect(coordinator.session == nil)
	}

	/// Ambient infrastructure alongside a proven player must not veto the press —
	/// the gate asks whether *any* rendering pid has been seen to move.
	@Test func ambientRendererAlongsideAProvenPlayerStillPresses() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			ambient: [Self.constantRenderer],
			script: [[42, Self.constantRenderer]])

		#expect(coordinator.plausiblePlayerIsRendering())

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// The player is proven but stopped; what is left rendering is ambient. There
	/// is nothing to pause, so the key could only start something.
	@Test func provenPlayerThatStoppedLeavesOnlyAmbientAndNoPress() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: [[Self.constantRenderer], [Self.constantRenderer]])

		coordinator.observeOnce()
		#expect(!coordinator.plausiblePlayerIsRendering())

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 0)
		#expect(coordinator.session == nil)
	}

	// MARK: - Resume

	@Test func resumeBringsBackWhatWePaused() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: holdingThroughFastWindow([42, Self.constantRenderer])
				+ [
					[Self.constantRenderer],  // slow poll: 42 stopped
					[Self.constantRenderer],  // resume baseline
					[Self.constantRenderer, 42],  // resume poll: 42 is back
				])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
		#expect(coordinator.session == nil)
	}

	/// The session exists only because we watched pid 42 stop, so seeing it play
	/// again means the user restarted it by hand; the toggle would stop it.
	@Test func resumeSkipsPlaybackTheUserRestarted() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: holdingThroughFastWindow([42, Self.constantRenderer])
				+ [
					[Self.constantRenderer],
					[Self.constantRenderer, 42],  // resume baseline: already playing
				])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 1)
	}

	/// A resume that wakes a *different* app is the same mistake as a pause that
	/// starts one, and gets the same undo.
	@Test func resumeThatStartsADifferentAppUndoesItself() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: holdingThroughFastWindow([42, Self.constantRenderer])
				+ [
					[Self.constantRenderer],
					[Self.constantRenderer],
					[Self.constantRenderer, 99],  // resume poll: wrong app woke up
				])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 3)
	}

	@Test func staleSessionIsNotResumed() async {
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: holdingThroughFastWindow([42, Self.constantRenderer])
				+ [[Self.constantRenderer], [Self.constantRenderer], [Self.constantRenderer, 42]])

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
		let (coordinator, recorder) = makeCoordinator(
			toggled: [42],
			script: holdingThroughFastWindow([42, Self.constantRenderer])
				+ [[Self.constantRenderer], [Self.constantRenderer], [Self.constantRenderer, 42]])

		await coordinator.pauseBeforeDictation()
		await coordinator.flush()
		coordinator.resumeAfterDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.keyPresses == 2)
	}
}
