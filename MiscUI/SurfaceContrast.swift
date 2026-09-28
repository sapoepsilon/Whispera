import AppKit
import SwiftUI

/// Translucent materials take most of their colour from what is behind the window. In light
/// mode over a dark wallpaper that leaves dark text on a mid-grey, so every translucent surface
/// gets a layer of the window background colour underneath its content, strongest in light mode.
enum SurfaceContrast {
	static func backingOpacity(
		style: MaterialStyle,
		colorScheme: ColorScheme,
		increasedContrast: Bool = false,
		reduceTransparency: Bool = false
	) -> Double {
		if increasedContrast || reduceTransparency { return 1 }
		switch colorScheme {
		case .light:
			switch style {
			case .ultraThin: return 0.82
			case .thin: return 0.78
			case .regular: return 0.74
			case .thick: return 0.72
			case .ultraThick: return 0.7
			}
		default:
			switch style {
			case .ultraThin: return 0.45
			case .thin: return 0.38
			case .regular: return 0.3
			case .thick: return 0.2
			case .ultraThick: return 0.1
			}
		}
	}

	/// Tint for Liquid Glass surfaces, which have no material style of their own.
	static func glassTintOpacity(colorScheme: ColorScheme, increasedContrast: Bool = false) -> Double {
		if increasedContrast { return 0.9 }
		return colorScheme == .light ? 0.6 : 0.3
	}
}

struct AdaptiveMaterialBackground<S: InsettableShape>: View {
	let style: MaterialStyle
	let shape: S

	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var contrast
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

	init(style: MaterialStyle, shape: S) {
		self.style = style
		self.shape = shape
	}

	var body: some View {
		ZStack {
			shape.fill(style.material)
			shape.fill(
				Color(nsColor: .windowBackgroundColor).opacity(
					SurfaceContrast.backingOpacity(
						style: style,
						colorScheme: colorScheme,
						increasedContrast: contrast == .increased,
						reduceTransparency: reduceTransparency
					)))
		}
	}
}

extension AdaptiveMaterialBackground where S == Rectangle {
	init(style: MaterialStyle) {
		self.init(style: style, shape: Rectangle())
	}
}

@available(macOS 26.0, *)
struct AdaptiveGlassModifier: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var contrast

	func body(content: Content) -> some View {
		content.glassEffect(
			.regular.tint(
				Color(nsColor: .windowBackgroundColor).opacity(
					SurfaceContrast.glassTintOpacity(
						colorScheme: colorScheme, increasedContrast: contrast == .increased))))
	}
}
