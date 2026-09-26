import AppKit
import Foundation
import Testing

@testable import Whispera

struct CancelShortcutTests {
	@Test func plainEscapeMatches() {
		#expect(CancelShortcut.matches(keyCode: 53, modifiers: []))
	}

	@Test func escapeWithNonShortcutFlagsStillMatches() {
		#expect(CancelShortcut.matches(keyCode: 53, modifiers: [.capsLock, .function]))
	}

	@Test(arguments: [
		NSEvent.ModifierFlags.command, .option, .control, .shift,
	])
	func escapeWithShortcutModifierDoesNotMatch(modifier: NSEvent.ModifierFlags) {
		#expect(!CancelShortcut.matches(keyCode: 53, modifiers: modifier))
	}

	@Test func otherKeysDoNotMatch() {
		#expect(!CancelShortcut.matches(keyCode: 15, modifiers: []))
	}

	@Test func cancelShortcutIsEnabledByDefault() {
		let defaults = UserDefaults(suiteName: "CancelShortcutTests.\(UUID().uuidString)")!
		#expect(RecordingControlSettings(defaults: defaults).cancelShortcutEnabled)
	}

	@Test func cancelShortcutCanBeDisabled() {
		let defaults = UserDefaults(suiteName: "CancelShortcutTests.\(UUID().uuidString)")!
		defaults.set(false, forKey: RecordingControlSettings.Key.cancelShortcutEnabled)
		#expect(!RecordingControlSettings(defaults: defaults).cancelShortcutEnabled)
	}
}

@MainActor
struct CancelShortcutMonitorTests {
	@Test func activatesAndDeactivates() {
		let monitor = CancelShortcutMonitor {}
		#expect(!monitor.isActive)
		monitor.setActive(true)
		#expect(monitor.isActive)
		monitor.setActive(true)
		#expect(monitor.isActive)
		monitor.setActive(false)
		#expect(!monitor.isActive)
	}
}

@MainActor
struct CancelRecordingIdleTests {
	@Test func cancelWhenIdleIsANoOp() {
		let manager = AudioManager()
		manager.cancelRecording()
		#expect(manager.currentState == .idle)
		#expect(manager.lastTranscription == nil)
	}
}

@MainActor
struct CancelShortcutSecureInputTests {
	@Test func duplicateEscapeFromTwoSourcesCancelsOnce() {
		var cancels = 0
		let monitor = CancelShortcutMonitor(isSecureInputEnabled: { false }) { cancels += 1 }
		let t0 = Date()
		monitor.fire(now: t0)
		monitor.fire(now: t0.addingTimeInterval(0.1))
		#expect(cancels == 1)
		monitor.fire(now: t0.addingTimeInterval(1))
		#expect(cancels == 2)
	}

	@Test func claimsEscapeAsASystemHotKeyOnlyUnderSecureInput() {
		var secure = false
		let monitor = CancelShortcutMonitor(isSecureInputEnabled: { secure }) {}
		monitor.setActive(true)
		#expect(!monitor.isSecureInputHotKeyRegistered)

		secure = true
		monitor.reconcileSecureInput()
		#expect(monitor.isSecureInputHotKeyRegistered)

		secure = false
		monitor.reconcileSecureInput()
		#expect(!monitor.isSecureInputHotKeyRegistered)

		secure = true
		monitor.reconcileSecureInput()
		monitor.setActive(false)
		#expect(!monitor.isSecureInputHotKeyRegistered)
	}

	@Test func inactiveMonitorNeverClaimsEscape() {
		let monitor = CancelShortcutMonitor(isSecureInputEnabled: { true }) {}
		monitor.reconcileSecureInput()
		#expect(!monitor.isSecureInputHotKeyRegistered)
	}
}
