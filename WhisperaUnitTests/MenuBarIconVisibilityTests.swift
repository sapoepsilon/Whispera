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

struct StatusItemPlacementTests {
	private let screen = NSRect(x: 0, y: 0, width: 1133, height: 744)
	private let slot = NSRect(x: 900, y: 720, width: 24, height: 24)

	@Test func settledOnceTheButtonSitsInTheMenuBarAndStopsMoving() {
		#expect(StatusItemPlacement.isSettled(windowFrame: slot, previousFrame: slot, screenFrames: [screen]))
	}

	@Test func notSettledOnTheFirstSighting() {
		#expect(!StatusItemPlacement.isSettled(windowFrame: slot, previousFrame: nil, screenFrames: [screen]))
	}

	@Test func notSettledWhileStillMoving() {
		let earlier = NSRect(x: 1133, y: 720, width: 24, height: 24)
		#expect(!StatusItemPlacement.isSettled(windowFrame: slot, previousFrame: earlier, screenFrames: [screen]))
	}

	@Test func notSettledAtTheScreenOriginOrPastTheRightEdge() {
		let origin = NSRect(x: 0, y: 0, width: 24, height: 24)
		#expect(!StatusItemPlacement.isSettled(windowFrame: origin, previousFrame: origin, screenFrames: [screen]))
		let offRight = NSRect(x: 1133, y: 720, width: 24, height: 24)
		#expect(!StatusItemPlacement.isSettled(windowFrame: offRight, previousFrame: offRight, screenFrames: [screen]))
	}

	@Test func notSettledWithAnEmptyFrame() {
		let empty = NSRect(x: 900, y: 744, width: 0, height: 0)
		#expect(!StatusItemPlacement.isSettled(windowFrame: empty, previousFrame: empty, screenFrames: [screen]))
	}

	@Test func settledInTheMenuBarOfASecondScreen() {
		let second = NSRect(x: 1133, y: 0, width: 1920, height: 1080)
		let slotOnSecond = NSRect(x: 2800, y: 1056, width: 24, height: 24)
		#expect(
			StatusItemPlacement.isSettled(
				windowFrame: slotOnSecond, previousFrame: slotOnSecond, screenFrames: [screen, second]))
	}
}
