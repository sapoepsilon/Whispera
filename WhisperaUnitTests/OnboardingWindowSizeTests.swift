import AppKit
import Testing

@testable import Whispera

struct OnboardingWindowSizeTests {
	/// A 13-inch MacBook at default scaling leaves 714 pt below the menu bar; the old fixed
	/// 750 pt window (782 pt with its title bar) ran off the bottom, hiding Back and Continue.
	@Test func fitsASmallLaptopScreen() {
		let visible = NSRect(x: 0, y: 0, width: 1133, height: 714)
		let titleBar: CGFloat = 32
		let height = OnboardingWindowSize.contentHeight(availableHeight: visible.height - titleBar)
		let frame = NSSize(width: OnboardingWindowSize.width, height: height + titleBar)
		let origin = OnboardingWindowSize.origin(for: frame, in: visible)
		#expect(origin.y >= visible.minY)
		#expect(origin.y + frame.height <= visible.maxY)
		#expect(origin.x >= visible.minX)
		#expect(origin.x + frame.width <= visible.maxX)
	}

	@Test func largeScreensKeepThePreferredHeight() {
		#expect(OnboardingWindowSize.contentHeight(availableHeight: 1_200) == OnboardingWindowSize.preferredHeight)
	}

	@Test func tinyScreensStopAtTheMinimum() {
		#expect(OnboardingWindowSize.contentHeight(availableHeight: 300) == OnboardingWindowSize.minimumHeight)
	}

	@Test func staysBelowTheMenuBarOnASecondScreen() {
		let visible = NSRect(x: 1133, y: 100, width: 1920, height: 1050)
		let size = NSSize(width: 600, height: 782)
		let origin = OnboardingWindowSize.origin(for: size, in: visible)
		#expect(origin.x > visible.minX)
		#expect(origin.y + size.height <= visible.maxY)
	}
}
