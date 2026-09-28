import AppKit
import Foundation
import Testing

@testable import Whispera

struct AppThemeTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "AppThemeTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsToSystemWhenUnset() {
		#expect(AppTheme.stored(in: isolatedDefaults()) == .system)
	}

	@Test func unknownStoredValueFallsBackToSystem() {
		let defaults = isolatedDefaults()
		defaults.set("sepia", forKey: AppTheme.defaultsKey)
		#expect(AppTheme.stored(in: defaults) == .system)
	}

	@Test(arguments: AppTheme.allCases)
	func persistsRoundTrip(theme: AppTheme) {
		let defaults = isolatedDefaults()
		defaults.set(theme.rawValue, forKey: AppTheme.defaultsKey)
		#expect(AppTheme.stored(in: defaults) == theme)
	}

	@Test func mapsToAppKitAppearances() {
		#expect(AppTheme.system.appearanceName == nil)
		#expect(AppTheme.light.appearanceName == .aqua)
		#expect(AppTheme.dark.appearanceName == .darkAqua)
	}

	@MainActor
	@Test func applySetsAndClearsApplicationAppearance() {
		let original = NSApp.appearance
		defer { NSApp.appearance = original }

		ThemeController.shared.apply(.dark)
		#expect(NSApp.appearance?.name == .darkAqua)
		ThemeController.shared.apply(.light)
		#expect(NSApp.appearance?.name == .aqua)
		ThemeController.shared.apply(.system)
		#expect(NSApp.appearance == nil)
	}

	/// The menu bar popover does not inherit NSApp.appearance, so it listens for this instead.
	@MainActor
	@Test func applyingANewThemeAnnouncesIt() {
		let original = NSApp.appearance
		defer {
			ThemeController.shared.apply(.system)
			NSApp.appearance = original
		}
		ThemeController.shared.apply(.system)
		final class Counter: @unchecked Sendable { var value = 0 }
		let received = Counter()
		let observer = NotificationCenter.default.addObserver(
			forName: AppTheme.didChangeNotification, object: nil, queue: nil
		) { _ in received.value += 1 }
		defer { NotificationCenter.default.removeObserver(observer) }

		ThemeController.shared.apply(.light)
		ThemeController.shared.apply(.dark)
		let afterChanges = received.value
		ThemeController.shared.apply(.dark)

		#expect(afterChanges == 2)
		#expect(received.value == 2)
	}
}
