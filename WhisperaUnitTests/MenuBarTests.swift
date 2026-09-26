import AppKit
import Testing

@testable import Whispera

// MARK: - Popover Positioning Tests
// Prevents re-introducing manual popover repositioning that detaches the arrow from the status icon

struct PopoverPositionTests {

	@Test func noStoredPopoverFrame() {
		let delegate = AppDelegate()
		let mirror = Mirror(reflecting: delegate)
		let hasPopoverFrame = mirror.children.contains { $0.label == "popoverFrame" }
		#expect(!hasPopoverFrame, "Manual popoverFrame storage breaks arrow alignment — NSPopover handles positioning natively")
	}

	@Test func noRestorePopoverMethod() {
		let delegate = AppDelegate()
		let mirror = Mirror(reflecting: delegate)
		let hasRestore = mirror.children.contains { $0.label == "restorePopoverPositionIfNeeded" }
		#expect(!hasRestore, "restorePopoverPositionIfNeeded moves the popover away from the anchor")
	}

	@Test func popoverDefaultBehavior() {
		let delegate = AppDelegate()
		// setupMenuBar() sets .semitransient — a fresh instance has default .applicationDefined
		// which proves no one accidentally hardcoded a different behavior at init time
		#expect(delegate.popover.behavior == .applicationDefined)
	}
}

struct NotificationBannerTests {
	/// The banner is overlaid on the popover's buttons; a see-through base let their labels show through.
	@Test func bannerHasAnOpaqueBase() {
		#expect(NotificationBanner.baseColor.usingColorSpace(.sRGB)?.alphaComponent == 1)
	}
}
