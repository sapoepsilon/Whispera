import Foundation
import Testing

@testable import Whispera

struct MediaPauseScanTests {

	@Test func nilOutputParsesToNothing() {
		#expect(MediaPauseScan.parse(nil) == MediaPauseScan())
	}

	@Test func emptyOutputParsesToNothing() {
		#expect(MediaPauseScan.parse("|") == MediaPauseScan())
	}

	@Test func splitsPausedFromBlocked() {
		let scan = MediaPauseScan.parse("music safari |chrome ")
		#expect(scan.paused == [.music, .safari])
		#expect(scan.blocked == [.chrome])
	}

	@Test func deduplicatesRepeatedBlockedTokens() {
		let scan = MediaPauseScan.parse("|safari safari safari ")
		#expect(scan.blocked == [.safari])
	}

	@Test func ignoresUnknownTokens() {
		let scan = MediaPauseScan.parse("music vlc|firefox")
		#expect(scan.paused == [.music])
		#expect(scan.blocked.isEmpty)
	}

	@Test func outputWithoutSeparatorHasNoBlockedSegment() {
		let scan = MediaPauseScan.parse("spotify ")
		#expect(scan.paused == [.spotify])
		#expect(scan.blocked.isEmpty)
	}

	@Test func twoSegmentOutputCarriesNoIdentity() {
		#expect(MediaPauseScan.parse("safari |").identity == nil)
	}

	@Test func emptyIdentitySegmentIsNoIdentity() {
		#expect(MediaPauseScan.parse("music ||").identity == nil)
		#expect(MediaPauseScan.parse("music ||  \n").identity == nil)
	}

	@Test func identitySegmentIsTrimmed() {
		#expect(MediaPauseScan.parse("music ||AB12CD\n").identity == "AB12CD")
	}
}

struct MediaPauseSessionTests {
	let start = Date(timeIntervalSinceReferenceDate: 0)

	@Test func blockedBrowsersAloneStartNoSession() {
		let scan = MediaPauseScan(paused: [], blocked: [.safari, .chrome])
		#expect(MediaPauseSession.started(from: scan, at: start) == nil)
	}

	@Test func pausedTargetsStartASession() {
		let scan = MediaPauseScan(paused: [.spotify, .edge], blocked: [])
		#expect(MediaPauseSession.started(from: scan, at: start)?.targets == [.spotify, .edge])
	}

	@Test func resumesInsideTheGap() {
		let session = MediaPauseSession(targets: [.music], startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(30)))
	}

	@Test func gapBoundaryStillResumes() {
		let session = MediaPauseSession(targets: [.music], startedAt: start)
		#expect(session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap)))
	}

	@Test func skipsResumeBeyondTheGap() {
		let session = MediaPauseSession(targets: [.music], startedAt: start)
		#expect(!session.shouldResume(at: start.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)))
	}
}

struct MediaSweepTargetTests {

	@Test func playersOnly() {
		#expect(MediaPlaybackCoordinator.sweepTargets(players: true, browsers: false) == [.music, .spotify])
	}

	@Test func browsersOnly() {
		#expect(
			MediaPlaybackCoordinator.sweepTargets(players: false, browsers: true)
				== [.safari, .chrome, .edge, .brave])
	}

	@Test func everythingDisabledSweepsNothing() {
		#expect(MediaPlaybackCoordinator.sweepTargets(players: false, browsers: false).isEmpty)
	}

	@Test func everythingEnabledSweepsAllTargets() {
		#expect(
			MediaPlaybackCoordinator.sweepTargets(players: true, browsers: true)
				== MediaTarget.allCases)
	}
}

struct MediaPauseScriptTests {

	@Test(arguments: MediaTarget.allCases)
	func pauseScriptNeverLaunchesTheApp(target: MediaTarget) {
		#expect(
			MediaPlaybackCoordinator.pauseScript(for: target)
				.contains("if application \"\(target.rawValue)\" is running then"))
	}

	@Test(arguments: MediaTarget.allCases)
	func pauseScriptEchoesOnlyItsOwnToken(target: MediaTarget) {
		let script = MediaPlaybackCoordinator.pauseScript(for: target)
		for other in MediaTarget.allCases where other != target {
			#expect(!script.contains("\"\(other.token) \""))
		}
	}

	@Test func playerPauseScriptChecksPlayerState() {
		let script = MediaPlaybackCoordinator.pauseScript(for: .spotify)
		#expect(script.contains("if player state is playing then"))
		#expect(!script.contains("javascript"))
	}

	@Test func playerPauseScriptCapturesTheTrackItPaused() {
		let music = MediaPlaybackCoordinator.pauseScript(for: .music)
		#expect(music.contains("persistent ID of current track"))
		#expect(music.contains("return pausedList & \"|\" & blockedList & \"|\" & trackIdentity"))

		let spotify = MediaPlaybackCoordinator.pauseScript(for: .spotify)
		#expect(spotify.contains("id of current track"))
		#expect(!spotify.contains("persistent ID"))
	}

	@Test func browserPauseScriptStaysTwoSegments() {
		let script = MediaPlaybackCoordinator.pauseScript(for: .safari)
		#expect(script.contains("return pausedList & \"|\" & blockedList"))
		#expect(!script.contains("trackIdentity"))
	}

	@Test func browserPauseScriptReportsBlockedTabsInsteadOfFallingBack() {
		let script = MediaPlaybackCoordinator.pauseScript(for: .chrome)
		#expect(script.contains("on error"))
		#expect(script.contains("blockedList"))
		#expect(!script.contains("player state"))
	}

	@Test func safariUsesDoJavaScriptAndChromiumUsesExecute() {
		#expect(MediaPlaybackCoordinator.pauseScript(for: .safari).contains("do JavaScript"))
		for chromium in [MediaTarget.chrome, .edge, .brave] {
			#expect(MediaPlaybackCoordinator.pauseScript(for: chromium).contains("execute t javascript"))
		}
	}

	@Test func pauseTabScriptOnlyTouchesPlayingElementsAndTagsThem() {
		#expect(MediaPlaybackCoordinator.pauseTabScript.contains("!m.paused"))
		#expect(MediaPlaybackCoordinator.pauseTabScript.contains("whisperaPaused"))
	}

	@Test func resumeTabScriptOnlySelectsTaggedElements() {
		#expect(MediaPlaybackCoordinator.resumeTabScript.contains("data-whispera-paused"))
		#expect(MediaPlaybackCoordinator.resumeTabScript.contains("if(m.paused)"))
	}

	@Test func embeddedJavaScriptSurvivesAppleScriptQuoting() {
		for js in [MediaPlaybackCoordinator.pauseTabScript, MediaPlaybackCoordinator.resumeTabScript] {
			#expect(!js.contains("\""))
			#expect(!js.contains("\\"))
		}
	}

	@Test func playerResumeScriptRechecksPlayerState() {
		let script = MediaPlaybackCoordinator.resumeScript(for: .music, identity: "AB12")
		#expect(script.contains("if player state is paused then"))
	}

	@Test func playerResumeScriptOnlyPlaysTheTrackItPaused() {
		let script = MediaPlaybackCoordinator.resumeScript(for: .music, identity: "AB12")
		#expect(script.contains("if currentIdentity is \"AB12\" then play"))
		#expect(script.contains("persistent ID of current track"))
	}

	@Test func playerResumeScriptNeverStartsAStoppedPlayer() {
		let script = MediaPlaybackCoordinator.resumeScript(for: .spotify, identity: "spotify:track:1")
		#expect(!script.contains("is not playing"))
		#expect(script.contains("is running"))
	}

	@Test func browserResumeScriptReplaysOnlyTaggedElements() {
		let script = MediaPlaybackCoordinator.resumeScript(for: .edge, identity: "")
		#expect(script.contains("data-whispera-paused"))
		#expect(!script.contains("player state"))
	}
}

struct MediaBlockedRecoveryMessageTests {

	@Test func namesEveryBlockedBrowser() {
		let message = MediaPlaybackCoordinator.blockedRecoveryMessage(for: [.safari, .chrome, .brave])
		#expect(message.contains("Safari"))
		#expect(message.contains("Google Chrome"))
		#expect(message.contains("Brave Browser"))
	}

	@Test func safariGetsTheDevelopMenuRecovery() {
		let message = MediaPlaybackCoordinator.blockedRecoveryMessage(for: [.safari])
		#expect(message.contains("Develop > Allow JavaScript from Apple Events"))
		#expect(message.contains("Settings > Advanced"))
		#expect(!message.contains("View > Developer"))
	}

	@Test(arguments: [MediaTarget.chrome, .edge, .brave])
	func chromiumGetsTheViewDeveloperRecovery(target: MediaTarget) {
		let message = MediaPlaybackCoordinator.blockedRecoveryMessage(for: [target])
		#expect(message.contains("View > Developer > Allow JavaScript from Apple Events"))
		#expect(!message.contains("Settings > Advanced"))
	}

	@Test func bothFamiliesGetTheirOwnStep() {
		let message = MediaPlaybackCoordinator.blockedRecoveryMessage(for: [.safari, .edge])
		#expect(message.contains("Develop > Allow JavaScript from Apple Events"))
		#expect(message.contains("View > Developer > Allow JavaScript from Apple Events"))
	}

	@Test func noBlockedBrowsersMeansNoMessage() {
		#expect(MediaPlaybackCoordinator.blockedRecoveryMessage(for: []).isEmpty)
	}
}

/// Captures scripts across the coordinator's detached tasks. File-scoped so it
/// stays nonisolated: nested inside the @MainActor suite it would inherit that
/// isolation, and the coordinator's @Sendable closures call it off-main.
private final class ScriptRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var _scripts: [String] = []
	private var _output: String?
	private var _now = Date(timeIntervalSinceReferenceDate: 0)

	var scripts: [String] { lock.withLock { _scripts } }
	var output: String? {
		get { lock.withLock { _output } }
		set { lock.withLock { _output = newValue } }
	}
	var now: Date {
		get { lock.withLock { _now } }
		set { lock.withLock { _now = newValue } }
	}

	func run(_ script: String) -> String? {
		lock.withLock {
			_scripts.append(script)
			return _output
		}
	}
}

/// Stands in for the CoreAudio muter. By default it silences nothing, so every
/// blocked browser handed to it comes back as audible-but-unmutable — the
/// behaviour of a machine that cannot tap at all.
private final class MuteRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var _muteCalls: [[MediaTarget]] = []
	private var _unmuteCalls = 0
	private var _mutable: Set<MediaTarget> = []

	var muteCalls: [[MediaTarget]] { lock.withLock { _muteCalls } }
	var unmuteCalls: Int { lock.withLock { _unmuteCalls } }

	func allowMuting(_ targets: Set<MediaTarget>) { lock.withLock { _mutable = targets } }

	func mute(_ targets: [MediaTarget]) -> ([MediaTarget], [MediaTarget]) {
		lock.withLock { () -> ([MediaTarget], [MediaTarget]) in
			_muteCalls.append(targets)
			return (
				targets.filter { _mutable.contains($0) },
				targets.filter { !_mutable.contains($0) }
			)
		}
	}

	func unmute() { lock.withLock { _unmuteCalls += 1 } }
}

/// Collects `.browserMediaPauseBlocked` payloads from the @Sendable observer
/// block, which can neither mutate a captured local nor touch main-actor state.
private final class BlockedNotificationRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var _payloads: [[String]] = []

	var payloads: [[String]] { lock.withLock { _payloads } }

	func record(_ browsers: [String]) { lock.withLock { _payloads.append(browsers) } }
}

@MainActor
struct MediaPlaybackCoordinatorFlowTests {

	/// `mutes` defaults to a throwaway recorder so no test ever reaches the real
	/// CoreAudio muter; tests that assert on muting pass in their own.
	private func makeCoordinator(
		playersEnabled: Bool = true,
		browsersEnabled: Bool = true,
		mutes: MuteRecorder = MuteRecorder()
	) -> (MediaPlaybackCoordinator, ScriptRecorder) {
		let recorder = ScriptRecorder()
		let coordinator = MediaPlaybackCoordinator(
			playersEnabled: { playersEnabled },
			browsersEnabled: { browsersEnabled },
			runScript: { recorder.run($0) },
			muteBlocked: { mutes.mute($0) },
			unmuteBlocked: { mutes.unmute() },
			now: { recorder.now }
		)
		return (coordinator, recorder)
	}

	/// Scoped to one coordinator: suites run in parallel and other tests drive
	/// blocked sweeps through the same default center.
	private func observeBlocked(
		_ coordinator: MediaPlaybackCoordinator,
		_ posts: BlockedNotificationRecorder
	) -> NSObjectProtocol {
		NotificationCenter.default.addObserver(
			forName: .browserMediaPauseBlocked,
			object: coordinator,
			queue: nil
		) { notification in
			posts.record(notification.userInfo?[MediaPlaybackCoordinator.blockedBrowsersKey] as? [String] ?? [])
		}
	}

	private let sweepCount = MediaTarget.allCases.count

	@Test func resumeReplaysExactlyWhatThePauseSweepPaused() async {
		let (coordinator, recorder) = makeCoordinator()
		// One fixture answers every target's sweep; only the player reads the
		// identity segment, so Safari is unaffected by it.
		recorder.output = "music safari ||MID"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		let resumes = Array(recorder.scripts.dropFirst(sweepCount))
		#expect(resumes.count == 2)
		#expect(resumes[0].contains("\"Music\""))
		#expect(resumes[1].contains("\"Safari\""))
		#expect(!resumes.contains { $0.contains("\"Spotify\"") || $0.contains("\"Google Chrome\"") })
	}

	@Test func nothingPlayingMeansNoResumeScript() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "|"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func blockedBrowserNeverTriggersAResume() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "|safari "

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func failedScriptsCountAsNothingPaused() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = nil

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func resumeWithoutPauseRunsNothing() async {
		let (coordinator, recorder) = makeCoordinator()

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.isEmpty)
	}

	@Test func secondResumeForOneDictationIsANoOp() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "spotify ||SID"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount + 1)
	}

	@Test func staleSessionIsNotResumed() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "music ||MID"

		coordinator.pauseForDictation()
		await coordinator.flush()
		recorder.now = recorder.now.addingTimeInterval(MediaPauseSession.maxResumeGap + 1)
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func disabledSettingsRunNoScripts() async {
		let (coordinator, recorder) = makeCoordinator(playersEnabled: false, browsersEnabled: false)
		recorder.output = "music |"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.isEmpty)
	}

	@Test func blockedBrowserAnnouncesItselfOnce() async {
		let (coordinator, recorder) = makeCoordinator()
		let posts = BlockedNotificationRecorder()
		let observer = observeBlocked(coordinator, posts)
		defer { NotificationCenter.default.removeObserver(observer) }
		recorder.output = "|safari "

		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(posts.payloads == [["Safari"]])

		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(posts.payloads == [["Safari"]])
	}

	@Test func aBrowserBlockedLaterGetsItsOwnAnnouncement() async {
		let (coordinator, recorder) = makeCoordinator()
		let posts = BlockedNotificationRecorder()
		let observer = observeBlocked(coordinator, posts)
		defer { NotificationCenter.default.removeObserver(observer) }

		recorder.output = "|safari "
		coordinator.pauseForDictation()
		await coordinator.flush()

		recorder.output = "|chrome "
		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(posts.payloads == [["Safari"], ["Google Chrome"]])
	}

	@Test func nothingBlockedAnnouncesNothing() async {
		let (coordinator, recorder) = makeCoordinator()
		let posts = BlockedNotificationRecorder()
		let observer = observeBlocked(coordinator, posts)
		defer { NotificationCenter.default.removeObserver(observer) }
		recorder.output = "music |"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(posts.payloads.isEmpty)
	}

	@Test func blockedAnnouncementCarriesTheRecoveryMessage() async {
		let (coordinator, recorder) = makeCoordinator()
		let messages = BlockedNotificationRecorder()
		let observer = NotificationCenter.default.addObserver(
			forName: .browserMediaPauseBlocked,
			object: coordinator,
			queue: nil
		) { notification in
			messages.record([notification.userInfo?[MediaPlaybackCoordinator.blockedMessageKey] as? String ?? ""])
		}
		defer { NotificationCenter.default.removeObserver(observer) }
		recorder.output = "|safari "

		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(
			messages.payloads.first?.first
				== MediaPlaybackCoordinator.blockedRecoveryMessage(for: [.safari]))
	}

	@Test func browsersOnlyModeSweepsOnlyBrowsers() async {
		let (coordinator, recorder) = makeCoordinator(playersEnabled: false, browsersEnabled: true)
		recorder.output = "chrome |"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		let browserCount = MediaTarget.allCases.filter(\.isBrowser).count
		#expect(recorder.scripts.count == browserCount + 1)
		#expect(!recorder.scripts.prefix(browserCount).contains { $0.contains("\"Music\"") })
		#expect(recorder.scripts.last?.contains("\"Google Chrome\"") == true)
	}

	@Test func playerWithoutACapturedTrackIsNeverResumed() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "music ||"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func playerResumeCarriesTheCapturedTrack() async {
		let (coordinator, recorder) = makeCoordinator(playersEnabled: true, browsersEnabled: false)
		recorder.output = "music ||ABC"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.last?.contains("\"ABC\"") == true)
	}

	@Test func mutedBrowserReplacesTheRecoveryNotification() async {
		let mutes = MuteRecorder()
		mutes.allowMuting([.safari])
		let (coordinator, recorder) = makeCoordinator(mutes: mutes)
		let posts = BlockedNotificationRecorder()
		let observer = observeBlocked(coordinator, posts)
		defer { NotificationCenter.default.removeObserver(observer) }
		recorder.output = "|safari "

		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(mutes.muteCalls == [[.safari]])
		#expect(posts.payloads.isEmpty)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(mutes.unmuteCalls == 1)
		// Muting and unmuting are CoreAudio, not AppleScript.
		#expect(recorder.scripts.count == sweepCount)
	}

	@Test func audibleButUnmutableBrowserStillAnnouncesItselfOnce() async {
		let mutes = MuteRecorder()
		let (coordinator, recorder) = makeCoordinator(mutes: mutes)
		let posts = BlockedNotificationRecorder()
		let observer = observeBlocked(coordinator, posts)
		defer { NotificationCenter.default.removeObserver(observer) }
		recorder.output = "|safari "

		coordinator.pauseForDictation()
		coordinator.pauseForDictation()
		await coordinator.flush()

		#expect(posts.payloads == [["Safari"]])
	}

	@Test func resumeWithNothingPausedStillLiftsTheMute() async {
		let mutes = MuteRecorder()
		let (coordinator, _) = makeCoordinator(mutes: mutes)

		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(mutes.unmuteCalls == 1)
	}
}
