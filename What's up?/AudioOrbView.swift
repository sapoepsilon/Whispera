import SwiftUI

struct AudioOrbView: View {
	let audioLevel: Float
	@State private var startDate = Date()

	private let orbSize: CGFloat = 80

	var body: some View {
		TimelineView(.animation) { timeline in
			let elapsed = timeline.date.timeIntervalSince(startDate)
			Canvas { context, size in
				context.addFilter(.colorMultiply(.white))
				let rect = CGRect(origin: .zero, size: size)
				context.fill(Path(rect), with: .color(.clear))
			}
			.frame(width: orbSize, height: orbSize)
			.colorEffect(
				ShaderLibrary.audioOrb(
					.float2(Float(orbSize), Float(orbSize)),
					.float(Float(elapsed)),
					.float(audioLevel)
				)
			)
		}
	}
}

#Preview {
	AudioOrbView(audioLevel: 0.5)
		.frame(width: 120, height: 120)
		.background(.black)
}
