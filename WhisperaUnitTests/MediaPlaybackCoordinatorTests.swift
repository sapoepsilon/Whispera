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
		let script = MediaPlaybackCoordinator.resumeScript(for: .music)
		#expect(script.contains("if player state is not playing then play"))
	}

	@Test func browserResumeScriptReplaysOnlyTaggedElements() {
		let script = MediaPlaybackCoordinator.resumeScript(for: .edge)
		#expect(script.contains("data-whispera-paused"))
		#expect(!script.contains("player state"))
	}
}

@MainActor
struct MediaPlaybackCoordinatorFlowTests {

	/// Captures scripts across the coordinator's detached tasks.
	final class ScriptRecorder: @unchecked Sendable {
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

	private func makeCoordinator(
		playersEnabled: Bool = true,
		browsersEnabled: Bool = true
	) -> (MediaPlaybackCoordinator, ScriptRecorder) {
		let recorder = ScriptRecorder()
		let coordinator = MediaPlaybackCoordinator(
			playersEnabled: { playersEnabled },
			browsersEnabled: { browsersEnabled },
			runScript: { recorder.run($0) },
			now: { recorder.now }
		)
		return (coordinator, recorder)
	}

	private let sweepCount = MediaTarget.allCases.count

	@Test func resumeReplaysExactlyWhatThePauseSweepPaused() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "music safari |"

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
		recorder.output = "spotify |"

		coordinator.pauseForDictation()
		coordinator.resumeAfterDictation()
		coordinator.resumeAfterDictation()
		await coordinator.flush()

		#expect(recorder.scripts.count == sweepCount + 1)
	}

	@Test func staleSessionIsNotResumed() async {
		let (coordinator, recorder) = makeCoordinator()
		recorder.output = "music |"

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
}
