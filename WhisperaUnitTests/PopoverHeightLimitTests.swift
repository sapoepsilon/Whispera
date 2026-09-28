import CoreGraphics
import Testing

@testable import Whispera

struct PopoverHeightLimitTests {

	@Test func shortContentKeepsTheMinimumHeight() {
		let layout = PopoverHeightLimit(contentHeight: 120, visibleScreenHeight: 900)
		#expect(layout.height == PopoverHeightLimit.minHeight)
		#expect(!layout.scrolls)
	}

	@Test func contentBetweenTheLimitsIsShownWhole() {
		let layout = PopoverHeightLimit(contentHeight: 742.3, visibleScreenHeight: 1000)
		#expect(layout.height == 743)
		#expect(!layout.scrolls)
	}

	/// The secure-input banner used to push the last card past a fixed 700 pt cap.
	@Test func tallContentIsNotCappedAtTheOldFixedMaximum() {
		let layout = PopoverHeightLimit(contentHeight: 760, visibleScreenHeight: 1080)
		#expect(layout.height == 760)
		#expect(!layout.scrolls)
	}

	@Test func contentTallerThanTheScreenScrollsInsteadOfClipping() {
		let layout = PopoverHeightLimit(contentHeight: 1200, visibleScreenHeight: 900)
		#expect(layout.height == 900 - PopoverHeightLimit.screenMargin)
		#expect(layout.scrolls)
	}

	@Test func tinyScreensStillGetTheMinimumAndScroll() {
		let layout = PopoverHeightLimit(contentHeight: 600, visibleScreenHeight: 150)
		#expect(layout.height == PopoverHeightLimit.minHeight)
		#expect(layout.scrolls)
	}

	@Test func unknownScreenUsesTheFallbackHeight() {
		let layout = PopoverHeightLimit(contentHeight: 2000, visibleScreenHeight: nil)
		#expect(layout.height == PopoverHeightLimit.fallbackScreenHeight - PopoverHeightLimit.screenMargin)
		#expect(layout.scrolls)
	}
}
