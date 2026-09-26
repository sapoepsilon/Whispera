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

	@Test func claimsACustomBindingUnderSecureInput() throws {
		let binding = try #require(CancelShortcutBinding(keyCode: 96, modifiers: [.option], characters: nil))
		let monitor = CancelShortcutMonitor(binding: { binding }, isSecureInputEnabled: { true }) {}
		monitor.setActive(true)
		#expect(monitor.isSecureInputHotKeyRegistered)
		monitor.setActive(false)
		#expect(!monitor.isSecureInputHotKeyRegistered)
		#expect(CancelShortcut.carbonSpec(for: .escape) == CancelShortcut.carbonSpec)
		#expect(
			CancelShortcut.carbonSpec(for: binding)
				== CarbonHotKeyMapping.spec(keyCode: 96, modifiers: [.option]))
	}
}

struct CancelShortcutBindingTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "CancelShortcutBindingTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToEscape() {
		let settings = RecordingControlSettings(defaults: makeDefaults())
		#expect(settings.cancelShortcut == .escape)
		#expect(settings.cancelShortcut.display == "Esc")
	}

	@Test func roundTripsThroughUserDefaults() throws {
		let defaults = makeDefaults()
		let settings = RecordingControlSettings(defaults: defaults)
		let binding = try #require(
			CancelShortcutBinding(keyCode: 40, modifiers: [.command, .shift, .capsLock], characters: "k"))
		settings.cancelShortcut = binding

		let reloaded = RecordingControlSettings(defaults: defaults).cancelShortcut
		#expect(reloaded == binding)
		#expect(reloaded.display == "⌘⇧K")
		#expect(reloaded.modifiers == [.command, .shift], "Caps Lock must not become part of the binding")
	}

	@Test func settingEscapeOrResettingClearsStoredValues() throws {
		let defaults = makeDefaults()
		let settings = RecordingControlSettings(defaults: defaults)
		settings.cancelShortcut = try #require(CancelShortcutBinding(keyCode: 111, modifiers: [], characters: nil))
		#expect(defaults.object(forKey: RecordingControlSettings.CancelKey.keyCode) != nil)
		settings.cancelShortcut = .escape
		#expect(defaults.object(forKey: RecordingControlSettings.CancelKey.keyCode) == nil)

		settings.cancelShortcut = try #require(CancelShortcutBinding(keyCode: 111, modifiers: [], characters: nil))
		settings.resetCancelShortcut()
		#expect(settings.cancelShortcut == .escape)
	}

	@Test func matchesOnlyItsOwnKeyAndModifiers() throws {
		let binding = try #require(CancelShortcutBinding(keyCode: 40, modifiers: [.command], characters: "k"))
		#expect(binding.matches(keyCode: 40, modifiers: [.command]))
		#expect(binding.matches(keyCode: 40, modifiers: [.command, .function, .capsLock]))
		#expect(!binding.matches(keyCode: 40, modifiers: []))
		#expect(!binding.matches(keyCode: 40, modifiers: [.command, .shift]))
		#expect(!binding.matches(keyCode: 53, modifiers: []))
		#expect(CancelShortcut.matches(keyCode: 40, modifiers: [.command], binding: binding))
	}

	@Test func namesSpecialKeys() {
		#expect(CancelShortcutBinding(keyCode: 111, modifiers: [], characters: nil)?.display == "F12")
		#expect(CancelShortcutBinding(keyCode: 122, modifiers: [.option], characters: nil)?.display == "⌥F1")
		#expect(CancelShortcutBinding(keyCode: 49, modifiers: [.control], characters: " ")?.display == "⌃Space")
		#expect(CancelShortcutBinding(keyCode: 53, modifiers: [], characters: "\u{1b}") == .escape)
		#expect(CancelShortcutBinding(keyCode: 999, modifiers: [], characters: nil) == nil)
	}

	@Test func bareTypingKeysNeedAModifier() throws {
		let bareK = try #require(CancelShortcutBinding(keyCode: 40, modifiers: [], characters: "k"))
		#expect(bareK.rejection(taken: []) == .needsModifier)
		let bareSpace = try #require(CancelShortcutBinding(keyCode: 49, modifiers: [], characters: " "))
		#expect(bareSpace.rejection(taken: []) == .needsModifier)

		let bareF5 = try #require(CancelShortcutBinding(keyCode: 96, modifiers: [], characters: nil))
		#expect(bareF5.rejection(taken: []) == nil)
		let bareDelete = try #require(CancelShortcutBinding(keyCode: 51, modifiers: [], characters: nil))
		#expect(bareDelete.rejection(taken: []) == nil)
	}

	@Test func rejectsAnotherWhisperaShortcut() throws {
		let binding = try #require(CancelShortcutBinding(keyCode: 15, modifiers: [.command, .option], characters: "r"))
		#expect(binding.rejection(taken: ["⌘⌥R", "⌃F"]) == .sameAsShortcut("⌘⌥R"))
		#expect(binding.rejection(taken: ["⌃F"]) == nil)
	}

	@MainActor
	@Test func monitorReadsTheConfiguredBinding() throws {
		let binding = try #require(CancelShortcutBinding(keyCode: 96, modifiers: [], characters: nil))
		var reads = 0
		let monitor = CancelShortcutMonitor(binding: {
			reads += 1
			return binding
		}) {}
		monitor.setActive(true)
		#expect(reads == 1)
		monitor.setActive(false)
	}
}
