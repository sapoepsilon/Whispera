import Foundation
import Testing

@testable import Whispera

struct ActivationStateMachineTests {
	private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

	private func machine(_ mode: ActivationMode, threshold: TimeInterval = 0.3) -> ActivationStateMachine {
		ActivationStateMachine(mode: mode, holdThreshold: threshold)
	}

	// MARK: Toggle

	@Test func toggleStartsOnPressAndIgnoresRelease() {
		var m = machine(.toggle)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyUp(at: t0.addingTimeInterval(2), isSessionActive: true) == .none)
	}

	@Test func toggleStopsOnSecondPress() {
		var m = machine(.toggle)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		_ = m.keyUp(at: t0.addingTimeInterval(0.1), isSessionActive: true)
		#expect(m.keyDown(at: t0.addingTimeInterval(1), isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyUp(at: t0.addingTimeInterval(1.1), isSessionActive: false) == .none)
	}

	@Test func keyRepeatIsIgnored() {
		var m = machine(.toggle)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyDown(at: t0.addingTimeInterval(0.5), isRepeat: true, isSessionActive: true) == .none)
		#expect(m.keyDown(at: t0.addingTimeInterval(5), isRepeat: true, isSessionActive: true) == .none)
	}

	@Test func duplicatePressFromASecondSourceIsIgnored() {
		var m = machine(.toggle)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyDown(at: t0.addingTimeInterval(0.1), isRepeat: false, isSessionActive: true) == .none)
	}

	@Test func missedKeyUpDoesNotDeadenTheShortcutInToggleMode() {
		var m = machine(.toggle)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		// No keyUp delivered
		#expect(m.keyDown(at: t0.addingTimeInterval(2), isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyUp(at: t0.addingTimeInterval(2.1), isSessionActive: false) == .none)
		#expect(m.keyDown(at: t0.addingTimeInterval(4), isRepeat: false, isSessionActive: false) == .start)
	}

	@Test func missedKeyUpInPushToTalkLetsTheNextPressStop() {
		var m = machine(.pushToTalk)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyDown(at: t0.addingTimeInterval(3), isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyUp(at: t0.addingTimeInterval(3.2), isSessionActive: false) == .none)
	}

	@Test func resetClearsAStuckPress() {
		var m = machine(.pushToTalk)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		m.reset()
		#expect(!m.isPressed)
		#expect(m.keyDown(at: t0.addingTimeInterval(0.1), isRepeat: false, isSessionActive: false) == .start)
	}

	@Test func toggleWorksWithoutAnyReleaseEvents() {
		var m = machine(.toggle)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(!m.isPressed)
		#expect(m.keyDown(at: t0.addingTimeInterval(2), isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyDown(at: t0.addingTimeInterval(4), isRepeat: false, isSessionActive: false) == .start)
	}

	@Test func releaseModesIgnoreADuplicatePressBeforeRelease() {
		for mode in [ActivationMode.pushToTalk, .holdOrToggle] {
			var m = machine(mode)
			#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
			#expect(m.keyDown(at: t0.addingTimeInterval(0.1), isRepeat: false, isSessionActive: true) == .none)
		}
	}

	@Test func onlyReleaseDrivenModesNeedKeyUpEvents() {
		#expect(!ActivationMode.toggle.needsKeyRelease)
		#expect(ActivationMode.pushToTalk.needsKeyRelease)
		#expect(ActivationMode.holdOrToggle.needsKeyRelease)
	}

	// MARK: Push to talk

	@Test func pushToTalkRecordsWhileHeld() {
		var m = machine(.pushToTalk)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyUp(at: t0.addingTimeInterval(3), isSessionActive: true) == .stop)
	}

	@Test func pushToTalkStopsEvenOnAVeryShortPress() {
		var m = machine(.pushToTalk)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		#expect(m.keyUp(at: t0.addingTimeInterval(0.05), isSessionActive: true) == .stop)
	}

	@Test func pushToTalkPressDuringExternallyStartedRecordingStopsIt() {
		var m = machine(.pushToTalk)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyUp(at: t0.addingTimeInterval(1), isSessionActive: false) == .none)
	}

	@Test func releaseWithoutSessionDoesNothing() {
		var m = machine(.pushToTalk)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		#expect(m.keyUp(at: t0.addingTimeInterval(1), isSessionActive: false) == .none)
	}

	@Test func releaseWithoutPressDoesNothing() {
		var m = machine(.pushToTalk)
		#expect(m.keyUp(at: t0, isSessionActive: true) == .none)
	}

	// MARK: Hold or toggle

	@Test func holdOrToggleShortTapKeepsRecording() {
		var m = machine(.holdOrToggle, threshold: 0.3)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyUp(at: t0.addingTimeInterval(0.1), isSessionActive: true) == .none)
		#expect(m.keyDown(at: t0.addingTimeInterval(2), isRepeat: false, isSessionActive: true) == .stop)
		#expect(m.keyUp(at: t0.addingTimeInterval(2.1), isSessionActive: false) == .none)
	}

	@Test func holdOrToggleLongHoldStopsOnRelease() {
		var m = machine(.holdOrToggle, threshold: 0.3)
		#expect(m.keyDown(at: t0, isRepeat: false, isSessionActive: false) == .start)
		#expect(m.keyUp(at: t0.addingTimeInterval(0.35), isSessionActive: true) == .stop)
	}

	@Test func holdOrToggleRespectsCustomThreshold() {
		var m = machine(.holdOrToggle, threshold: 0.8)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		#expect(m.keyUp(at: t0.addingTimeInterval(0.5), isSessionActive: true) == .none)
	}

	@Test func resetClearsPress() {
		var m = machine(.pushToTalk)
		_ = m.keyDown(at: t0, isRepeat: false, isSessionActive: false)
		m.reset()
		#expect(!m.isPressed)
		#expect(m.keyUp(at: t0.addingTimeInterval(1), isSessionActive: true) == .none)
	}
}

struct ActivationSettingsTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "ActivationSettingsTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToToggleAnd300ms() {
		let settings = RecordingControlSettings(defaults: makeDefaults())
		#expect(settings.activationMode == .toggle)
		#expect(settings.holdThreshold == 0.3)
	}

	@Test func readsStoredMode() {
		let defaults = makeDefaults()
		defaults.set(ActivationMode.pushToTalk.rawValue, forKey: RecordingControlSettings.Key.activationMode)
		#expect(RecordingControlSettings(defaults: defaults).activationMode == .pushToTalk)
	}

	@Test func clampsHoldThreshold() {
		let defaults = makeDefaults()
		defaults.set(5, forKey: RecordingControlSettings.Key.holdThresholdMs)
		#expect(RecordingControlSettings(defaults: defaults).holdThreshold == 0.1)
		defaults.set(99_999, forKey: RecordingControlSettings.Key.holdThresholdMs)
		#expect(RecordingControlSettings(defaults: defaults).holdThreshold == 1.0)
	}
}
