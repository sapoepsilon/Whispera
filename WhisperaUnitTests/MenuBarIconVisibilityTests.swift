import Foundation
import Testing

@testable import Whispera

struct MenuBarIconVisibilityTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "MenuBarIconVisibilityTests.\(UUID().uuidString)")!
	}

	@Test func iconIsShownByDefault() {
		let visibility = MenuBarIconVisibility(defaults: makeDefaults())
		#expect(visibility.settingShown)
		#expect(visibility.isVisible)
	}

	@Test func storedSettingHidesTheIcon() {
		let defaults = makeDefaults()
		defaults.set(false, forKey: MenuBarIconVisibility.defaultsKey)
		#expect(!MenuBarIconVisibility(defaults: defaults).isVisible)
	}

	@Test func reopeningRevealsAHiddenIconUntilItsMenuCloses() {
		var visibility = MenuBarIconVisibility(settingShown: false)

		let revealed = visibility.revealForReopen()
		#expect(revealed)
		#expect(visibility.isVisible)
		#expect(!visibility.settingShown)

		visibility.menuClosed()
		#expect(!visibility.isVisible)
	}

	@Test func reopeningWithTheIconShownChangesNothing() {
		var visibility = MenuBarIconVisibility(settingShown: true)
		let revealed = visibility.revealForReopen()
		#expect(!revealed)
		visibility.menuClosed()
		#expect(visibility.isVisible)
	}

	@Test func turningTheSettingBackOnKeepsTheIconAfterTheMenuCloses() {
		var visibility = MenuBarIconVisibility(settingShown: false)
		visibility.revealForReopen()
		visibility.updateSetting(true)
		visibility.menuClosed()
		#expect(visibility.isVisible)
	}

	@Test func hidingFromSettingsWhileRevealedHidesOnMenuClose() {
		var visibility = MenuBarIconVisibility(settingShown: true)
		visibility.updateSetting(false)
		#expect(!visibility.isVisible)
		visibility.revealForReopen()
		#expect(visibility.isVisible)
		visibility.menuClosed()
		#expect(!visibility.isVisible)
	}
}
