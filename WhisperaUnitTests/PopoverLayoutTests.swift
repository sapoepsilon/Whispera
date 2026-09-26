import CoreGraphics
import Testing

@testable import Whispera

struct PopoverLayoutTests {

	@Test func shortContentKeepsTheMinimumHeight() {
		let layout = PopoverLayout(contentHeight: 250, visibleScreenHeight: 900)
		#expect(layout.height == PopoverLayout.minHeight)
		#expect(!layout.scrolls)
	}

	@Test func contentBetweenTheLimitsIsShownWhole() {
		let layout = PopoverLayout(contentHeight: 742.3, visibleScreenHeight: 1000)
		#expect(layout.height == 743)
		#expect(!layout.scrolls)
	}

	/// The secure-input banner used to push the last card past a fixed 700 pt cap.
	@Test func tallContentIsNotCappedAtTheOldFixedMaximum() {
		let layout = PopoverLayout(contentHeight: 760, visibleScreenHeight: 1080)
		#expect(layout.height == 760)
		#expect(!layout.scrolls)
	}

	@Test func contentTallerThanTheScreenScrollsInsteadOfClipping() {
		let layout = PopoverLayout(contentHeight: 1200, visibleScreenHeight: 900)
		#expect(layout.height == 900 - PopoverLayout.screenMargin)
		#expect(layout.scrolls)
	}

	@Test func tinyScreensStillGetTheMinimumAndScroll() {
		let layout = PopoverLayout(contentHeight: 600, visibleScreenHeight: 300)
		#expect(layout.height == PopoverLayout.minHeight)
		#expect(layout.scrolls)
	}

	@Test func unknownScreenUsesTheFallbackHeight() {
		let layout = PopoverLayout(contentHeight: 2000, visibleScreenHeight: nil)
		#expect(layout.height == PopoverLayout.fallbackScreenHeight - PopoverLayout.screenMargin)
		#expect(layout.scrolls)
	}
}
