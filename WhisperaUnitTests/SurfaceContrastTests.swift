import AppKit
import SwiftUI
import Testing

@testable import Whispera

struct SurfaceContrastTests {

	private struct RGB {
		var r: Double
		var g: Double
		var b: Double
		var a: Double

		init(_ color: NSColor, appearance: NSAppearance.Name) {
			var resolved = NSColor.black
			NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
				resolved = color.usingColorSpace(.sRGB) ?? .black
			}
			r = resolved.redComponent
			g = resolved.greenComponent
			b = resolved.blueComponent
			a = resolved.alphaComponent
		}

		init(r: Double, g: Double, b: Double) {
			self.r = r
			self.g = g
			self.b = b
			a = 1
		}

		func over(_ backdrop: RGB, opacity: Double? = nil) -> RGB {
			let alpha = opacity ?? a
			return RGB(
				r: r * alpha + backdrop.r * (1 - alpha),
				g: g * alpha + backdrop.g * (1 - alpha),
				b: b * alpha + backdrop.b * (1 - alpha))
		}

		var luminance: Double {
			func channel(_ c: Double) -> Double {
				c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
			}
			return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
		}
	}

	private func contrast(_ a: RGB, _ b: RGB) -> Double {
		let (l1, l2) = (a.luminance, b.luminance)
		return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
	}

	/// Worst case for light mode: a black wallpaper, with the material itself counted as adding nothing.
	@Test(arguments: MaterialStyle.allCases)
	func lightModeTextStaysReadableOverABlackWallpaper(style: MaterialStyle) {
		let wallpaper = RGB(r: 0, g: 0, b: 0)
		let backing = RGB(NSColor.windowBackgroundColor, appearance: .aqua)
		let surface = backing.over(
			wallpaper, opacity: SurfaceContrast.backingOpacity(style: style, colorScheme: .light))

		let primary = RGB(NSColor.labelColor, appearance: .aqua).over(surface)
		let secondary = RGB(NSColor.secondaryLabelColor, appearance: .aqua).over(surface)

		#expect(contrast(primary, surface) >= 7, "primary text on \(style.rawValue)")
		#expect(contrast(secondary, surface) >= 3, "secondary text on \(style.rawValue)")
	}

	@Test(arguments: MaterialStyle.allCases)
	func darkModeKeepsMoreTranslucencyThanLightMode(style: MaterialStyle) {
		let dark = SurfaceContrast.backingOpacity(style: style, colorScheme: .dark)
		let light = SurfaceContrast.backingOpacity(style: style, colorScheme: .light)
		#expect(dark > 0)
		#expect(dark < light)
	}

	@Test func thickerMaterialsNeedLessBacking() {
		for scheme in [ColorScheme.light, .dark] {
			let values = MaterialStyle.allCases.map {
				SurfaceContrast.backingOpacity(style: $0, colorScheme: scheme)
			}
			#expect(values == values.sorted(by: >))
		}
	}

	@Test(arguments: [ColorScheme.light, .dark])
	func accessibilitySettingsMakeTheSurfaceOpaque(scheme: ColorScheme) {
		#expect(
			SurfaceContrast.backingOpacity(style: .ultraThin, colorScheme: scheme, increasedContrast: true)
				== 1)
		#expect(
			SurfaceContrast.backingOpacity(style: .ultraThin, colorScheme: scheme, reduceTransparency: true)
				== 1)
	}

	@Test func glassTintIsStrongerInLightMode() {
		#expect(
			SurfaceContrast.glassTintOpacity(colorScheme: .light)
				> SurfaceContrast.glassTintOpacity(colorScheme: .dark))
		#expect(SurfaceContrast.glassTintOpacity(colorScheme: .dark, increasedContrast: true) >= 0.9)
	}
}
