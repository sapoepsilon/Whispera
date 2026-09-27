import AppKit
import Foundation
import Testing

@testable import Whispera

/// Esc was only exercised in hold mode on the signed app, where the key-combination rule of the
/// held dictation key cancels first. In toggle mode the key is up while recording, so the cancel
/// shortcut alone has to do it, and the next tap must start a fresh recording.
@MainActor
struct CancelShortcutActivationModeTests {
	static let escape = ModifierOnlyInput(kind: .keyDown)
	static let rightCommandDown = ModifierOnlyInput(
		kind: .flagsChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)))
	static let rightCommandUp = ModifierOnlyInput(kind: .flagsChanged(keyCode: 54, flags: []))

	@Test func escapeCancelsAToggleRecordingAndTheNextTapStartsANewOne() {
		var shortcut = ModifierOnlyShortcutMachine(key: .rightCommand)
		var activation = ActivationStateMachine(mode: .toggle, holdThreshold: 0.3)
		let start = Date()

		#expect(shortcut.handle(Self.rightCommandDown, recorderListening: false, mode: .toggle, isSessionActive: false) == [])
		#expect(
			shortcut.handle(Self.rightCommandUp, recorderListening: false, mode: .toggle, isSessionActive: false)
				== [.keyDown, .keyUp])
		#expect(activation.keyDown(at: start, isRepeat: false, isSessionActive: false) == .start)
		#expect(activation.keyUp(at: start.addingTimeInterval(0.05), isSessionActive: true) == .none)

		// Esc while recording with the dictation key up: not a combination, so only the cancel
		// shortcut acts, and it is armed while the microphone records
		#expect(shortcut.handle(Self.escape, recorderListening: false, mode: .toggle, isSessionActive: true) == [])
		#expect(CancelShortcut.matches(keyCode: CancelShortcut.escapeKeyCode, modifiers: []))
		#expect(CancelShortcutPolicy.shouldListen(isRecording: true, isStarting: false, enabled: true))
		var cancels = 0
		CancelShortcutMonitor(isSecureInputEnabled: { false }) { cancels += 1 }.fire(now: start.addingTimeInterval(3))
		#expect(cancels == 1)

		// After the cancel the session is over, so the next tap starts instead of stopping
		#expect(shortcut.handle(Self.rightCommandDown, recorderListening: false, mode: .toggle, isSessionActive: false) == [])
		#expect(
			shortcut.handle(Self.rightCommandUp, recorderListening: false, mode: .toggle, isSessionActive: false)
				== [.keyDown, .keyUp])
		#expect(activation.keyDown(at: start.addingTimeInterval(5), isRepeat: false, isSessionActive: false) == .start)
		#expect(!CancelShortcutPolicy.shouldListen(isRecording: false, isStarting: false, enabled: true))
	}

	/// Hold mode: Esc while the key is held is a combination, which cancels the recording that
	/// press started; the cancel shortcut firing as well is harmless.
	@Test func escapeWhileHoldingCancelsThroughTheCombinationRule() {
		var shortcut = ModifierOnlyShortcutMachine(key: .rightCommand)
		var activation = ActivationStateMachine(mode: .pushToTalk, holdThreshold: 0.3)
		let start = Date()

		let pressed = shortcut.handle(
			Self.rightCommandDown, recorderListening: false, mode: .pushToTalk, isSessionActive: false)
		guard case .scheduleStart(let press, _) = pressed.first else {
			Issue.record("push to talk schedules the start: \(pressed)")
			return
		}
		#expect(shortcut.startDelayElapsed(press: press, isSessionActive: false) == [.keyDown])
		#expect(activation.keyDown(at: start, isRepeat: false, isSessionActive: false) == .start)

		#expect(shortcut.handle(Self.escape, recorderListening: false, mode: .pushToTalk, isSessionActive: true) == [.cancelSession])
		activation.reset()
		#expect(shortcut.handle(Self.rightCommandUp, recorderListening: false, mode: .pushToTalk, isSessionActive: false) == [])
		#expect(activation.keyUp(at: start.addingTimeInterval(1), isSessionActive: false) == .none)
		#expect(activation.keyDown(at: start.addingTimeInterval(2), isRepeat: false, isSessionActive: false) == .start)
	}
}
