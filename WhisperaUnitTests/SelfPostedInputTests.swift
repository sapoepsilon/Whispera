import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Whispera

/// Whispera's own pastes, typed text and live corrections reach its shortcut monitors like any
/// other keystroke. These feed the exact events the poster builds into the single-key shortcut
/// machine while the dictation key is held.
@MainActor
struct SelfPostedInputTests {
	private let rightCommandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
	private let rightOptionDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)

	private func poster(held: CGEventFlags = []) -> CGKeyEventPoster {
		CGKeyEventPoster(physicallyHeldFlags: { held }, send: { _ in })
	}

	/// Everything Whispera posts during a live session: the segment paste, typed text, and the
	/// Shift+Arrow selection and Cmd-Z undo of a correction.
	private func whisperaKeystrokes(held: CGEventFlags = []) -> [NSEvent] {
		let poster = poster(held: held)
		let cgEvents =
			poster.keyEvents(KeyCode.v, flags: .maskCommand)
			+ poster.unicodeEvents(Array("hello".utf16))
			+ poster.keyEvents(0x7B, flags: .maskShift)
			+ poster.keyEvents(0x06, flags: .maskCommand)
			+ poster.keyEvents(KeyCode.returnKey, flags: [])
		return cgEvents.compactMap { NSEvent(cgEvent: $0) }
	}

	@Test func everyPostedEventIsTagged() {
		let poster = poster()
		let events = poster.keyEvents(KeyCode.v, flags: .maskCommand) + poster.unicodeEvents(Array("a".utf16))
		#expect(events.count == 5)
		for event in events {
			#expect(SyntheticKeyEvent.isSelfPosted(event))
			if let nsEvent = NSEvent(cgEvent: event) {
				#expect(SyntheticKeyEvent.isSelfPosted(nsEvent))
			}
		}
	}

	@Test(arguments: [ModifierOnlyShortcut.rightCommand, .rightOption, .rightControl, .rightShift, .fn])
	func pastingWhileTheKeyIsHeldDoesNotCancelTheRecording(key: ModifierOnlyShortcut) {
		var machine = ModifierOnlyShortcutMachine(key: key)
		let down: NSEvent.ModifierFlags =
			switch key {
			case .rightCommand: rightCommandDown
			case .rightOption: rightOptionDown
			case .rightControl: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x2000)
			case .rightShift: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)
			case .fn: .function
			}
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: key.keyCode, flags: down))
		let pressSteps = machine.handle(press, recorderListening: false, mode: .pushToTalk, isSessionActive: false)
		guard case .scheduleStart(let pressID, _) = pressSteps.first else {
			Issue.record("Push to Talk press should schedule its start, got \(pressSteps)")
			return
		}
		#expect(machine.startDelayElapsed(press: pressID, isSessionActive: false) == [.keyDown])

		let keystrokes = whisperaKeystrokes()
		#expect(!keystrokes.isEmpty)
		for event in keystrokes {
			guard let input = ModifierOnlyInput(event: event) else { continue }
			#expect(input.isSelfPosted)
			#expect(machine.handle(input, recorderListening: false, mode: .pushToTalk, isSessionActive: true) == [])
		}

		let release = ModifierOnlyInput(kind: .flagsChanged(keyCode: key.keyCode, flags: []))
		#expect(machine.handle(release, recorderListening: false, mode: .pushToTalk, isSessionActive: true) == [.keyUp])
	}

	/// The same keystrokes typed by the user still make the press a combination.
	@Test func theUsersOwnKeystrokeStillCancels() {
		var machine = ModifierOnlyShortcutMachine(key: .rightCommand)
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: rightCommandDown))
		_ = machine.handle(press, recorderListening: false, mode: .pushToTalk, isSessionActive: false)
		#expect(machine.startDelayElapsed(press: 1, isSessionActive: false) == [.keyDown])
		#expect(
			machine.handle(
				ModifierOnlyInput(kind: .keyDown), recorderListening: false, mode: .pushToTalk, isSessionActive: true)
				== [.cancelSession])
	}

	@Test func hardwareStyleInputIsNotSelfPosted() {
		#expect(!ModifierOnlyInput(kind: .keyDown).isSelfPosted)
		let untagged = CGEvent(keyboardEventSource: nil, virtualKey: KeyCode.v, keyDown: true)!
		#expect(untagged.getIntegerValueField(.eventSourceUserData) != SyntheticKeyEvent.marker)
	}

	/// Toggle mode: a second dictation's paste arriving during a tap must not swallow the tap.
	@Test func toggleTapSurvivesAPasteInBetween() {
		var machine = ModifierOnlyShortcutMachine(key: .rightOption)
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: 61, flags: rightOptionDown))
		#expect(machine.handle(press, recorderListening: false, mode: .toggle, isSessionActive: false) == [])
		for event in whisperaKeystrokes() {
			guard let input = ModifierOnlyInput(event: event) else { continue }
			_ = machine.handle(input, recorderListening: false, mode: .toggle, isSessionActive: false)
		}
		let release = ModifierOnlyInput(kind: .flagsChanged(keyCode: 61, flags: []))
		#expect(
			machine.handle(release, recorderListening: false, mode: .toggle, isSessionActive: false) == [.keyDown, .keyUp])
	}
}

/// After a synthetic Cmd-V the session must not be left believing Command is down (a menu-bar
/// click then became a Cmd-drag), but a Command the user is physically holding must stay down.
struct ModifierReleasePolicyTests {
	private func captured(_ keyCode: CGKeyCode, flags: CGEventFlags, held: CGEventFlags) -> [CGEvent] {
		var sent: [CGEvent] = []
		let poster = CGKeyEventPoster(physicallyHeldFlags: { held }, send: { sent.append($0) })
		poster.postKey(keyCode, flags: flags)
		return sent
	}

	private func keyCode(_ event: CGEvent) -> CGKeyCode {
		CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
	}

	/// The original fix: nothing held, so Command is released after the paste.
	@Test func pasteReleasesCommandWhenTheUserIsNotHoldingIt() {
		let events = captured(KeyCode.v, flags: .maskCommand, held: [])
		#expect(events.map(keyCode) == [KeyCode.v, KeyCode.v, KeyCode.command])
		let release = events[2]
		#expect(!release.flags.contains(.maskCommand))
		#expect(release.type != .keyDown)
		#expect(SyntheticKeyEvent.isSelfPosted(release))
	}

	/// Live mode with Push to Talk on ⌥⌘R: the user is holding Command while segments paste.
	@Test func pasteLeavesAPhysicallyHeldCommandDown() {
		let events = captured(KeyCode.v, flags: .maskCommand, held: [.maskCommand, .maskAlternate])
		#expect(events.map(keyCode) == [KeyCode.v, KeyCode.v])
	}

	/// Right ⌥ Push to Talk: the Command release must not also tell apps Option went up.
	@Test func theReleaseKeepsOtherHeldModifiers() {
		let events = captured(KeyCode.v, flags: .maskCommand, held: [.maskAlternate, .maskAlphaShift])
		#expect(events.map(keyCode) == [KeyCode.v, KeyCode.v, KeyCode.command])
		#expect(events[2].flags.contains(.maskAlternate))
		#expect(!events[2].flags.contains(.maskCommand))
	}

	@Test func onlyTheModifiersTheUserIsNotHoldingAreReleased() {
		#expect(CGKeyEventPoster.modifierKeyCodes(toRelease: .maskCommand, physicallyHeld: []) == [KeyCode.command])
		#expect(CGKeyEventPoster.modifierKeyCodes(toRelease: .maskCommand, physicallyHeld: .maskCommand).isEmpty)
		#expect(
			CGKeyEventPoster.modifierKeyCodes(
				toRelease: [.maskCommand, .maskShift], physicallyHeld: [.maskCommand, .maskAlternate])
				== [KeyCode.shift])
		// Non-modifier bits in the held state (caps lock, fn) never block a release
		#expect(
			CGKeyEventPoster.modifierKeyCodes(toRelease: .maskShift, physicallyHeld: [.maskAlphaShift, .maskSecondaryFn])
				== [KeyCode.shift])
		#expect(CGKeyEventPoster.modifierKeyCodes(toRelease: [], physicallyHeld: []).isEmpty)
	}

	/// Live corrections select with Shift+Arrow; a held Shift (Right ⇧ Push to Talk) stays down.
	@Test func correctionStepsRespectAHeldShift() {
		#expect(captured(0x7B, flags: .maskShift, held: []).map(keyCode) == [0x7B, 0x7B, KeyCode.shift])
		#expect(captured(0x7B, flags: .maskShift, held: .maskShift).map(keyCode) == [0x7B, 0x7B])
	}

	@Test func plainKeysPostNoRelease() {
		#expect(captured(KeyCode.returnKey, flags: [], held: []).count == 2)
	}
}

/// Hold modes wait a moment before opening the microphone, so a capital letter typed with
/// Right ⇧ or a character typed with Right ⌥ never starts (and then cancels) a recording.
struct ModifierOnlyStartDelayTests {
	@Test func aChordBeforeTheDelayNeverStartsRecording() {
		var router = ModifierOnlyPressRouter()
		#expect(
			router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
				== [.scheduleStart(press: 1, delay: 0.2)])
		#expect(router.interrupted() == [])
		#expect(router.startDelayElapsed(press: 1, isSessionActive: false) == [])
		#expect(router.released() == [])
	}

	@Test func aHoldPastTheDelayStartsAndAChordThenCancels() {
		var router = ModifierOnlyPressRouter()
		_ = router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
		#expect(router.startDelayElapsed(press: 1, isSessionActive: false) == [.keyDown])
		#expect(router.interrupted() == [.cancelSession])
		#expect(router.released() == [])
	}

	@Test func aHoldPastTheDelayStopsOnRelease() {
		var router = ModifierOnlyPressRouter()
		_ = router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
		#expect(router.startDelayElapsed(press: 1, isSessionActive: false) == [.keyDown])
		#expect(router.released() == [.keyUp])
	}

	@Test func pushToTalkTapShorterThanTheDelayDoesNothing() {
		var router = ModifierOnlyPressRouter()
		_ = router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
		#expect(router.released() == [])
		#expect(router.startDelayElapsed(press: 1, isSessionActive: false) == [])
	}

	@Test func holdOrToggleTapStillStartsAndKeepsRecording() {
		var router = ModifierOnlyPressRouter()
		var machine = ActivationStateMachine(mode: .holdOrToggle, holdThreshold: 0.3)
		let at = Date()
		_ = router.pressed(mode: .holdOrToggle, isSessionActive: false, startDelay: 0.2)
		#expect(router.released() == [.keyDown, .keyUp])
		#expect(machine.keyDown(at: at, isRepeat: false, isSessionActive: false) == .start)
		#expect(machine.keyUp(at: at, isSessionActive: true) == .none)
	}

	@Test func aTimerFromAnEarlierPressIsIgnored() {
		var router = ModifierOnlyPressRouter()
		_ = router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
		_ = router.released()
		#expect(
			router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
				== [.scheduleStart(press: 2, delay: 0.2)])
		#expect(router.startDelayElapsed(press: 1, isSessionActive: false) == [])
		#expect(router.isStartPending)
		#expect(router.startDelayElapsed(press: 2, isSessionActive: false) == [.keyDown])
	}

	/// A recording started from the menu during the delay is not stopped by the held key.
	@Test func aSessionThatStartedElsewhereIsLeftAlone() {
		var router = ModifierOnlyPressRouter()
		_ = router.pressed(mode: .pushToTalk, isSessionActive: false, startDelay: 0.2)
		#expect(router.startDelayElapsed(press: 1, isSessionActive: true) == [])
		#expect(router.released() == [])
	}

	@Test func typingKeysWaitLongerThanShortcutKeys() {
		for key in ModifierOnlyShortcut.allCases {
			#expect(key.holdStartDelay > 0)
			#expect(key.holdStartDelay <= 0.25)
		}
		#expect(ModifierOnlyShortcut.rightShift.holdStartDelay >= ModifierOnlyShortcut.rightCommand.holdStartDelay)
		#expect(ModifierOnlyShortcut.rightOption.holdStartDelay >= ModifierOnlyShortcut.fn.holdStartDelay)
	}

	@Test func toggleModeIsNotDelayed() {
		var router = ModifierOnlyPressRouter()
		#expect(router.pressed(mode: .toggle, isSessionActive: false, startDelay: 0.2) == [])
		#expect(router.released() == [.keyDown, .keyUp])
	}
}

/// Tapping the current single-key shortcut in a recorder must not also start a dictation.
@MainActor
struct ShortcutRecorderPauseTests {
	private let rightCommandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)

	@Test func gateTracksEachRecorderSeparately() {
		let gate = ShortcutRecorderGate()
		#expect(!gate.isRecording)
		let settings = gate.begin()
		let onboarding = gate.begin()
		gate.end(settings)
		#expect(gate.isRecording)
		gate.end(onboarding)
		#expect(!gate.isRecording)
		gate.end(nil)
		gate.end(settings)
		#expect(!gate.isRecording)
	}

	@Test(arguments: ActivationMode.allCases)
	func aPressRecordedAsTheNewShortcutDoesNothing(mode: ActivationMode) {
		var machine = ModifierOnlyShortcutMachine(key: .rightCommand)
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: rightCommandDown))
		let release = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: []))
		#expect(machine.handle(press, recorderListening: true, mode: mode, isSessionActive: false) == [])
		#expect(machine.handle(release, recorderListening: true, mode: mode, isSessionActive: false) == [])
		#expect(!machine.router.isStartPending)
	}

	/// The recorder stops inside the release event, so the live monitor may see that release
	/// after the pause ended. The press it never saw leaves nothing for the release to act on.
	@Test(arguments: ActivationMode.allCases)
	func theReleaseAfterRecordingEndsDoesNothing(mode: ActivationMode) {
		var machine = ModifierOnlyShortcutMachine(key: .rightCommand)
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: rightCommandDown))
		let release = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: []))
		_ = machine.handle(press, recorderListening: true, mode: mode, isSessionActive: false)
		#expect(machine.handle(release, recorderListening: false, mode: mode, isSessionActive: false) == [])
	}

	/// A press that began before a recorder opened is dropped, so its release cannot stop or
	/// start anything once the recorder has finished.
	@Test func aPressInProgressIsForgottenWhenRecordingStarts() {
		var machine = ModifierOnlyShortcutMachine(key: .rightCommand)
		let press = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: rightCommandDown))
		#expect(machine.handle(press, recorderListening: false, mode: .toggle, isSessionActive: false) == [])
		_ = machine.handle(ModifierOnlyInput(kind: .keyDown), recorderListening: true, mode: .toggle, isSessionActive: false)
		let release = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: []))
		#expect(machine.handle(release, recorderListening: false, mode: .toggle, isSessionActive: false) == [])
	}
}

/// A key press that turns out to be a shortcut cancels only the capture it started.
@MainActor
struct PressCancelScopeTests {
	@Test func cancellingAnEndedCaptureLeavesTranscriptionsAlone() {
		var ledger = DictationSessionLedger()
		let (first, _) = ledger.beginCapture(mode: .text, postProcess: false)
		ledger.finishCapture()
		#expect(ledger.cancelCapture(id: first.id) == nil)
		#expect(ledger.isTranscribing(first.id))
		#expect(!ledger.isCancelled(first.id))
	}

	@Test func cancellingTheCurrentCaptureKeepsEarlierTranscriptions() {
		var ledger = DictationSessionLedger()
		let (first, _) = ledger.beginCapture(mode: .text, postProcess: false)
		ledger.finishCapture()
		let (second, _) = ledger.beginCapture(mode: .text, postProcess: false)
		#expect(ledger.cancelCapture(id: second.id) == second)
		#expect(!ledger.isCapturing(second.id))
		#expect(ledger.isTranscribing(first.id))
		#expect(!ledger.isCancelled(first.id))
	}

	@Test func aStaleIdLeavesANewerCaptureRunning() {
		var ledger = DictationSessionLedger()
		let (first, _) = ledger.beginCapture(mode: .text, postProcess: false)
		ledger.dropCapture()
		let (second, _) = ledger.beginCapture(mode: .text, postProcess: false)
		#expect(ledger.cancelCapture(id: first.id) == nil)
		#expect(ledger.isCapturing(second.id))
	}

	@Test func cancelCaptureWhenIdleIsANoOp() {
		let manager = AudioManager()
		manager.cancelCapture(sessionID: 1)
		#expect(manager.captureSessionID == nil)
		#expect(!manager.isSessionActive)
		#expect(!manager.isTranscribing)
	}
}
