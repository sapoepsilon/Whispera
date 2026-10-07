import AppKit
import Foundation
import Testing

@testable import Whispera

private func isolatedDefaults(_ name: String) -> (UserDefaults, () -> Void) {
	let suite = "UpgradeSafetyTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

struct LegacyShortcutTests {
	@Test(arguments: [
		("⌥ ", NSEvent.ModifierFlags.option, UInt16(49)),
		("⌃ ", .control, 49),
		("⌥\u{F708}", .option, 96),
		("⌘\u{F704}", .command, 122),
		("⌘\r", .command, 36),
		("⌃\u{1B}", .control, 53),
		("⌥\t", .option, 48),
		("⌥\u{F700}", .option, 126),
	])
	func onboardingStringsParseToThePressedKey(stored: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
		#expect(ShortcutCombo(stored) == ShortcutCombo(modifiers: modifiers, keyCode: keyCode))
	}

	@Test func existingNamesKeepTheirKeys() {
		#expect(ShortcutCombo("⌥⌘R") == ShortcutCombo(modifiers: [.option, .command], keyCode: 15))
		#expect(ShortcutCombo("⌘Enter")?.keyCode == 36)
		#expect(ShortcutCombo("⌥Space")?.keyCode == 49)
		#expect(ShortcutCombo("⌥⌘") == nil)
	}

	@Test func migrationRewritesOnlyUnreadableKeys() {
		#expect(ShortcutMigration.migrated("⌥ ") == "⌥Space")
		#expect(ShortcutMigration.migrated("⌘⌥\u{F708}") == "⌘⌥F5")
		#expect(ShortcutMigration.migrated("⌘\r") == "⌘Return")
		#expect(ShortcutMigration.migrated("⌥⌘R") == nil)
		#expect(ShortcutMigration.migrated("⌥⌘Space") == nil)
		#expect(ShortcutMigration.migrated("F5") == nil)
	}

	@Test func migrationUpdatesStoredShortcuts() {
		let (defaults, cleanup) = isolatedDefaults("migrate")
		defer { cleanup() }
		defaults.set("⌥ ", forKey: ShortcutDefaults.dictationKey)
		defaults.set("⌃F", forKey: ShortcutDefaults.fileSelectionKey)

		#expect(ShortcutMigration.migrate(in: defaults) == [ShortcutDefaults.dictationKey])
		#expect(defaults.string(forKey: ShortcutDefaults.dictationKey) == "⌥Space")
		#expect(defaults.string(forKey: ShortcutDefaults.fileSelectionKey) == "⌃F")
		#expect(ShortcutMigration.migrate(in: defaults).isEmpty)
	}

	@Test func recorderFormatsWhatTheParserReadsBack() {
		#expect(DictationShortcutFormatter.format(keyCode: 49, modifiers: .option) == "⌥Space")
		#expect(DictationShortcutFormatter.format(keyCode: 96, modifiers: []) == "F5")
		#expect(DictationShortcutFormatter.format(keyCode: 36, modifiers: .command) == "⌘Return")
		#expect(DictationShortcutFormatter.format(keyCode: 15, modifiers: []) == nil, "Plain R needs a modifier")
		#expect(DictationShortcutFormatter.format(keyCode: 49, modifiers: []) == nil)
		for keyCode in UInt16(0)...127 {
			for modifiers: NSEvent.ModifierFlags in [.option, [.command, .shift], .control] {
				guard let stored = DictationShortcutFormatter.format(keyCode: keyCode, modifiers: modifiers)
				else { continue }
				#expect(
					ShortcutCombo(stored) == ShortcutCombo(modifiers: modifiers, keyCode: keyCode),
					"\(stored) does not read back as key \(keyCode)")
			}
		}
	}

	@Test func unsetShortcutMeansTheSameEverywhere() {
		let (defaults, cleanup) = isolatedDefaults("unset")
		defer { cleanup() }
		#expect(ShortcutDefaults.dictation(in: defaults) == "⌥⌘R")
		#expect(ShortcutDefaults.fileSelection(in: defaults) == "⌃F")
		AppDelegate.registerInitialDefaults(in: defaults)
		#expect(defaults.string(forKey: ShortcutDefaults.dictationKey) == ShortcutDefaults.dictation)
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌥⌘R", defaults: defaults) == "⌥⌘R")
	}
}
