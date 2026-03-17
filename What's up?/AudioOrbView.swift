import SwiftUI
import MetalOrb

struct AudioOrbView: View {
	let audioLevel: Float
	let audioBands: [Float]

	@State private var preset = OrbPreset.transparent.values

	private var mappedBands: SIMD4<Float> {
		guard audioBands.count >= 4 else {
			return SIMD4<Float>(repeating: audioLevel)
		}
		// 7 bands → 4 groups: bass(0-1), mid(2-3), high(4-5), treble(6)
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
			audioBands: mappedBands
		)
	}
}
