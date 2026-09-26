import AppKit

/// The onboarding window was a fixed 750 pt tall, taller than the visible area of a 13-inch
/// display at its default scaling (714 pt), so Back and Continue sat below the bottom edge.
enum OnboardingWindowSize {
	static let width: CGFloat = 600
	static let preferredHeight: CGFloat = 750
	static let minimumHeight: CGFloat = 520
	static let screenMargin: CGFloat = 16

	/// `availableHeight` is the visible screen height minus the window's title bar.
	static func contentHeight(availableHeight: CGFloat) -> CGFloat {
		max(minimumHeight, min(preferredHeight, availableHeight - screenMargin))
	}

	/// Centered in the visible frame, and never above it, so the title bar stays reachable.
	static func origin(for size: NSSize, in visible: NSRect) -> NSPoint {
		let x = max(visible.minX, visible.midX - size.width / 2)
		let centeredY = visible.midY - size.height / 2
		let y = min(max(visible.minY, centeredY), visible.maxY - size.height)
		return NSPoint(x: x, y: y)
	}
}
