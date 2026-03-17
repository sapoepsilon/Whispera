import MetalOrb
import SwiftUI

struct AudioOrbView: View {
	let audioLevel: Float
	let audioBands: [Float]

	@State private var preset: OrbPresetValues = {
		var p = OrbPreset.transparent.values
		p.baseOpacity = 1.0
		p.lightIntensity = 1.6
		p.edgeGlow = 1.2
		p.heatIntensity = 0.3
		p.audioReactivity = 0.4
		p.color1 = OrbColor(1.0, 1.0, 1.0)
		p.color2 = OrbColor(0.95, 0.95, 1.0)
		p.color3 = OrbColor(1.0, 0.95, 0.95)
		p.color4 = OrbColor(0.95, 1.0, 0.95)
		return p
	}()

	private var mappedBands: SIMD4<Float> {
		guard audioBands.count >= 4 else {
			return SIMD4<Float>(repeating: audioLevel)
		}
		let bass = (audioBands[0] + audioBands[1]) / 2
		let mid = (audioBands[2] + audioBands[3]) / 2
		let high = (audioBands[4] + audioBands[5]) / 2
		let treble = audioBands.count > 6 ? audioBands[6] : high
		return SIMD4<Float>(bass, mid, high, treble)
	}

	var body: some View {
		MetalOrbView(
			preset: $preset,
			audioLevel: audioLevel,
			audioBands: mappedBands,
			transparentBackground: true
		)
	}
}
