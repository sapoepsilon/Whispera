import AppKit

/// The Settings toolbar shows one item per tab. When the labels do not fit, SwiftUI moves the
/// last tabs into an overflow menu whose items are disabled, so those tabs cannot be opened.
/// French and Spanish labels are longer than English ones, so the width follows the language.
enum SettingsWindowWidth {
	static let minimum: CGFloat = 880
	/// Space between two toolbar labels, measured on the Settings toolbar.
	static let itemSpacing: CGFloat = 13
	/// Leading and trailing toolbar insets plus slack so the last label never touches the edge.
	static let margins: CGFloat = 60

	static func required(
		forTabTitles titles: [String],
		font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
	) -> CGFloat {
		let labels = titles.reduce(CGFloat(0)) { total, title in
			total + ceil((title as NSString).size(withAttributes: [.font: font]).width)
		}
		let spacing = itemSpacing * CGFloat(max(titles.count - 1, 0))
		return max(minimum, ceil(labels + spacing + margins))
	}
}
