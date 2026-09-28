import AppKit
import Foundation
import Testing

@testable import Whispera

struct ModifierOnlyShortcutTests {
	/// Flags as a flagsChanged event reports them: the generic flag plus the side-specific bit.
	private func flags(_ generic: NSEvent.ModifierFlags, device: UInt = 0) -> NSEvent.ModifierFlags {
		NSEvent.ModifierFlags(rawValue: generic.rawValue | device)
	}

	private let rightOptionDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
	private let leftOptionDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)

	@Test func parsesStoredValuesIncludingOlderGlobeNames() {
		#expect(ModifierOnlyShortcut(stored: "Right Option") == .rightOption)
		#expect(ModifierOnlyShortcut(stored: "right command") == .rightCommand)
		#expect(ModifierOnlyShortcut(stored: "Globe") == .fn)
		#expect(ModifierOnlyShortcut(stored: "Fn") == .fn)
		#expect(ModifierOnlyShortcut(stored: "🌐") == .fn)
		#expect(ModifierOnlyShortcut(stored: "⌥⌘R") == nil)
		#expect(ModifierOnlyShortcut(stored: "⌘Globe") == nil)
		for key in ModifierOnlyShortcut.allCases {
			#expect(ModifierOnlyShortcut(stored: key.rawValue) == key)
			#expect(ModifierOnlyShortcut(keyCode: key.keyCode) == key)
		}
		// Left-side modifiers are part of nearly every shortcut, so they are never offered
		for leftKeyCode: UInt16 in [55, 58, 59, 56] {
			#expect(ModifierOnlyShortcut(keyCode: leftKeyCode) == nil)
		}
	}

	/// The key-combination parsers must not read these names, or the dictation shortcut would be
	/// reset as unreadable and the conflict checks would compare against an unrelated key.
	@Test func keyComboParsersIgnoreModifierOnlyValues() {
		for key in ModifierOnlyShortcut.allCases where key != .fn {
			#expect(ShortcutCombo(key.rawValue) == nil)
			#expect(ShortcutMigration.migrated(key.rawValue) == nil)
		}
	}

	@Test func otherWhisperaShortcutsDoNotClashWithAModifierOnlyDictationKey() {
		let suite = "ModifierOnlyShortcutTests.clash.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		defaults.set(ModifierOnlyShortcut.rightOption.rawValue, forKey: ShortcutDefaults.dictationKey)
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌥⇧Space", defaults: defaults) == nil)
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌃F", defaults: defaults) == "⌃F")
	}

	@Test func displayNamesReplaceStoredNames() {
		#expect(ShortcutDisplay.text(for: "Right Option") == ModifierOnlyShortcut.rightOption.displayName)
		#expect(ShortcutDisplay.text(for: "Globe") == ModifierOnlyShortcut.fn.displayName)
		#expect(ShortcutDisplay.text(for: "⌥⌘R") == "⌥⌘R")
	}

	@Test func rightAndLeftKeysAreToldApart() {
		#expect(ModifierOnlyShortcut.rightOption.isDown(in: rightOptionDown))
		#expect(!ModifierOnlyShortcut.rightOption.isDown(in: leftOptionDown))
		#expect(ModifierOnlyShortcut.fn.isDown(in: .function))
		#expect(!ModifierOnlyShortcut.fn.isDown(in: []))
	}

	@Test func trackerReportsPressAndRelease() {
		var tracker = ModifierOnlyKeyTracker(key: .rightOption)
		#expect(tracker.flagsChanged(keyCode: 61, flags: rightOptionDown) == .pressed)
		#expect(tracker.isDown)
		#expect(tracker.flagsChanged(keyCode: 61, flags: []) == .released)
		#expect(!tracker.isDown)
	}

	@Test func trackerIgnoresTheLeftKeyAndOtherModifiers() {
		var tracker = ModifierOnlyKeyTracker(key: .rightOption)
		#expect(tracker.flagsChanged(keyCode: 58, flags: leftOptionDown) == .none)
		#expect(tracker.flagsChanged(keyCode: 58, flags: []) == .none)
		#expect(tracker.flagsChanged(keyCode: 55, flags: .command) == .none)
		// Right Option pressed while Command is already down is a combination, not dictation
		#expect(tracker.flagsChanged(keyCode: 61, flags: flags([.command, .option], device: 0x40)) == .none)
		#expect(tracker.flagsChanged(keyCode: 61, flags: .command) == .none)
	}

	@Test func typingWhileHeldInterruptsOnce() {
		var tracker = ModifierOnlyKeyTracker(key: .rightOption)
		_ = tracker.flagsChanged(keyCode: 61, flags: rightOptionDown)
		#expect(tracker.keyDown() == .interrupted)
		#expect(tracker.keyDown() == .none)
		#expect(tracker.flagsChanged(keyCode: 61, flags: []) == .released)

		_ = tracker.flagsChanged(keyCode: 61, flags: rightOptionDown)
		#expect(
			tracker.flagsChanged(keyCode: 56, flags: flags([.option, .shift], device: 0x40 | 0x02))
				== .interrupted)
	}

	@Test func globeKeyIsTrackedThroughTheFunctionFlag() {
		var tracker = ModifierOnlyKeyTracker(key: .fn)
		#expect(tracker.flagsChanged(keyCode: 63, flags: .function) == .pressed)
		#expect(tracker.flagsChanged(keyCode: 63, flags: []) == .released)
	}

	/// Push to Talk: press starts, release stops, both through the shared activation machine.
	@Test func pushToTalkStartsOnPressAndStopsOnRelease() {
		var router = ModifierOnlyPressRouter()
		var machine = ActivationStateMachine(mode: .pushToTalk, holdThreshold: 0.3)
		let start = Date()

		#expect(router.pressed(mode: .pushToTalk, isSessionActive: false) == [.keyDown])
		#expect(machine.keyDown(at: start, isRepeat: false, isSessionActive: false) == .start)
		#expect(router.released() == [.keyUp])
		#expect(machine.keyUp(at: start.addingTimeInterval(2), isSessionActive: true) == .stop)
	}

	@Test func aCombinationCancelsTheRecordingItStarted() {
		var router = ModifierOnlyPressRouter()
		#expect(router.pressed(mode: .pushToTalk, isSessionActive: false) == [.keyDown])
		#expect(router.interrupted() == [.cancelSession])
		#expect(router.released() == [])
	}

	/// Toggle mode acts on a clean tap, so Right ⌘C or Right ⌥L never starts dictation.
	@Test func toggleActsOnCleanReleaseOnly() {
		var router = ModifierOnlyPressRouter()
		#expect(router.pressed(mode: .toggle, isSessionActive: false) == [])
		#expect(router.released() == [.keyDown, .keyUp])

		#expect(router.pressed(mode: .toggle, isSessionActive: false) == [])
		#expect(router.interrupted() == [])
		#expect(router.released() == [])
	}

	/// While recording, a press never stops it until it proves to be a tap, in any mode.
	@Test func stoppingWaitsForACleanRelease() {
		for mode in ActivationMode.allCases {
			var router = ModifierOnlyPressRouter()
			#expect(router.pressed(mode: mode, isSessionActive: true) == [])
			#expect(router.interrupted() == [])
			#expect(router.released() == [])

			#expect(router.pressed(mode: mode, isSessionActive: true) == [])
			#expect(router.released() == [.keyDown, .keyUp])
		}
	}

	@Test func holdOrToggleQuickTapKeepsRecording() {
		var router = ModifierOnlyPressRouter()
		var machine = ActivationStateMachine(mode: .holdOrToggle, holdThreshold: 0.3)
		let start = Date()
		#expect(router.pressed(mode: .holdOrToggle, isSessionActive: false) == [.keyDown])
		#expect(machine.keyDown(at: start, isRepeat: false, isSessionActive: false) == .start)
		#expect(router.released() == [.keyUp])
		#expect(machine.keyUp(at: start.addingTimeInterval(0.1), isSessionActive: true) == .none)
	}

	@Test func recorderCapturesALoneModifierTap() {
		var recording = ModifierOnlyRecording()
		#expect(recording.flagsChanged(keyCode: 54, flags: flags(.command, device: 0x10)) == nil)
		#expect(recording.flagsChanged(keyCode: 54, flags: []) == .rightCommand)

		#expect(recording.flagsChanged(keyCode: 63, flags: .function) == nil)
		#expect(recording.flagsChanged(keyCode: 63, flags: []) == .fn)
	}

	@Test func recorderLeavesCombinationsToTheKeyDownPath() {
		var recording = ModifierOnlyRecording()
		_ = recording.flagsChanged(keyCode: 54, flags: flags(.command, device: 0x10))
		recording.keyDown()
		#expect(recording.flagsChanged(keyCode: 54, flags: []) == nil)

		_ = recording.flagsChanged(keyCode: 61, flags: rightOptionDown)
		#expect(recording.flagsChanged(keyCode: 56, flags: flags([.option, .shift], device: 0x40 | 0x02)) == nil)
		#expect(recording.flagsChanged(keyCode: 61, flags: .shift) == nil)

		// A left modifier alone is not offered
		_ = recording.flagsChanged(keyCode: 58, flags: leftOptionDown)
		#expect(recording.flagsChanged(keyCode: 58, flags: []) == nil)
	}

	@Test func globeKeyIsFreeOnlyWhenSetToDoNothing() {
		#expect(!GlobeKeySetting.isClaimedBySystem(usage: 0))
		#expect(GlobeKeySetting.isClaimedBySystem(usage: 1))
		#expect(GlobeKeySetting.isClaimedBySystem(usage: 2))
		#expect(GlobeKeySetting.isClaimedBySystem(usage: 3))
		#expect(GlobeKeySetting.isClaimedBySystem(usage: nil))
	}
}
