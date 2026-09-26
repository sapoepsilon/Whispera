import CoreGraphics

/// Sizes the menu-bar popover to its content. Content taller than the screen allows scrolls
/// instead of being cut off, which matters with banners, long translations and large text.
struct PopoverHeightLimit: Equatable {
	static let minHeight: CGFloat = PopoverMetrics.minHeight
	/// Room for the menu bar gap, the popover arrow and a margin above the Dock.
	static let screenMargin: CGFloat = 48
	static let fallbackScreenHeight: CGFloat = 800

	let height: CGFloat
	let scrolls: Bool

	init(contentHeight: CGFloat, visibleScreenHeight: CGFloat?) {
		let available = (visibleScreenHeight ?? Self.fallbackScreenHeight) - Self.screenMargin
		let maxHeight = max(Self.minHeight, available)
		let content = contentHeight.rounded(.up)
		height = min(max(content, Self.minHeight), maxHeight)
		scrolls = content > maxHeight
	}
}
