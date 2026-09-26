import Foundation
import Observation
import Testing

@testable import Whispera

struct SettingsWindowOpeningTests {
	typealias State = SettingsWindowOpening.WindowState
	private let open = State(isVisible: true, isMiniaturized: false)
	private let minimized = State(isVisible: false, isMiniaturized: true)
	private let closed = State(isVisible: false, isMiniaturized: false)

	@Test func anOpenOrMinimizedWindowIsBroughtBack() {
		#expect(SettingsWindowOpening.firstStep(scene: minimized, retained: nil, canRequestScene: true) == .revealScene)
		#expect(SettingsWindowOpening.firstStep(scene: closed, retained: open, canRequestScene: true) == .revealRetained)
		#expect(SettingsWindowOpening.firstStep(scene: nil, retained: minimized, canRequestScene: true) == .revealRetained)
		#expect(SettingsWindowOpening.firstStep(scene: closed, retained: closed, canRequestScene: true) == .requestScene)
		#expect(SettingsWindowOpening.firstStep(scene: nil, retained: nil, canRequestScene: false) == .openRetained)
	}

	/// A slow first render used to get the fallback window on top of the scene window.
	@Test func aSceneWindowStillComingUpIsWaitedFor() {
		for check in 1..<SettingsWindowOpening.maxChecks {
			#expect(SettingsWindowOpening.stepAfterRequest(scene: closed, check: check) == .wait)
		}
		#expect(SettingsWindowOpening.stepAfterRequest(scene: open, check: 3) == .revealScene)
		#expect(SettingsWindowOpening.stepAfterRequest(scene: minimized, check: 1) == .revealScene)
		#expect(
			SettingsWindowOpening.stepAfterRequest(scene: closed, check: SettingsWindowOpening.maxChecks)
				== .openRetained)
	}

	@Test func aRequestThatProducedNoWindowFallsBackQuickly() {
		#expect(SettingsWindowOpening.stepAfterRequest(scene: nil, check: 1) == .wait)
		#expect(
			SettingsWindowOpening.stepAfterRequest(scene: nil, check: SettingsWindowOpening.noSceneChecks)
				== .openRetained)
	}
}

struct OnboardingModelChoiceTests {
	private let fetched = ["openai_whisper-base", "openai_whisper-small", "openai_whisper-small.en"]

	/// Re-running onboarding used to preselect Whisper small and download it, moving Parakeet and
	/// custom-model users off their model.
	@Test func rerunningOnboardingKeepsTheModelInUse() {
		let parakeet = "parakeet-tdt-0.6b-v3"
		let initial = OnboardingModelChoice.initial(current: parakeet, stored: "openai_whisper-base")
		#expect(initial == parakeet)
		#expect(OnboardingModelChoice.autoPick(selected: initial, available: fetched, downloaded: [parakeet]) == nil)
		#expect(
			OnboardingModelChoice.autoPick(
				selected: "custom:someone/model", available: fetched + ["custom:someone/model"], downloaded: [])
				== nil)
	}

	@Test func firstRunPicksMultilingualSmall() {
		let initial = OnboardingModelChoice.initial(current: nil, stored: "")
		#expect(initial.isEmpty)
		#expect(OnboardingModelChoice.autoPick(selected: initial, available: fetched, downloaded: []) == "openai_whisper-small")
	}

	@Test func aStoredModelIsUsedWhenNothingIsLoaded() {
		#expect(OnboardingModelChoice.initial(current: nil, stored: "openai_whisper-base") == "openai_whisper-base")
		#expect(
			OnboardingModelChoice.autoPick(selected: "openai_whisper-base", available: fetched, downloaded: []) == nil)
	}

	@Test func anUnknownSelectionIsReplaced() {
		#expect(
			OnboardingModelChoice.autoPick(selected: "gone-model", available: fetched, downloaded: [])
				== "openai_whisper-small")
		#expect(OnboardingModelChoice.autoPick(selected: "", available: [], downloaded: []) == "openai_whisper-small")
	}
}

@MainActor
struct QueueProgressPollerTests {
	/// A cancelled poll used to swallow the sleep's CancellationError and spin on the main actor
	/// while the item kept its processing status.
	@Test func aCancelledPollStopsEvenWhileTheItemStillLooksBusy() async {
		var ticks = 0
		let poll = Task { @MainActor in
			await QueueProgressPoller.run(while: { true }, interval: .milliseconds(20)) { ticks += 1 }
		}
		try? await Task.sleep(for: .milliseconds(70))
		poll.cancel()
		let finished = await withTaskGroup(of: Bool.self) { group in
			group.addTask { await poll.value; return true }
			group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
		#expect(finished)
		#expect(ticks < 20, "The poll kept ticking after cancel: \(ticks)")
	}

	@Test func pollEndsWhenTheItemStopsProcessing() async {
		var ticks = 0
		await QueueProgressPoller.run(while: { ticks < 3 }, interval: .milliseconds(1)) { ticks += 1 }
		#expect(ticks == 3)
	}
}

@MainActor
struct PermissionManagerPollingTests {
	@Test func unchangedChecksDoNotInvalidateObservers() {
		var microphone = true
		let manager = PermissionManager(
			microphoneCheck: { microphone }, accessibilityCheck: { true }, monitorsChanges: false)

		var changed = false
		withObservationTracking {
			_ = manager.microphonePermissionGranted
			_ = manager.accessibilityPermissionGranted
			_ = manager.needsPermissions
		} onChange: {
			changed = true
		}
		manager.updatePermissionStatus()
		#expect(!changed)

		microphone = false
		manager.updatePermissionStatus()
		#expect(changed)
		#expect(manager.needsPermissions)
	}

	@Test func pollsSlowlyOnceEverythingIsGranted() {
		#expect(PermissionManager.pollInterval(needsPermissions: true) == 2)
		#expect(PermissionManager.pollInterval(needsPermissions: false) >= 30)
	}
}
