import SwiftUI

struct ConfettiView: View {
	@State private var particles: [Particle] = []
	@State private var startTime: Date?

	private let colors: [Color] = [.blue, .purple, .green, .orange]
	private let particleCount = 25
	private let duration: TimeInterval = 2.5

	var body: some View {
		TimelineView(.animation) { timeline in
			Canvas { context, size in
				guard let start = startTime else { return }
				let elapsed = timeline.date.timeIntervalSince(start)

				for particle in particles {
					let progress = min(elapsed / particle.lifetime, 1.0)
					let easedProgress = 1 - pow(1 - progress, 2)

					let x = size.width / 2 + particle.startX + particle.velocityX * easedProgress
					let y = size.height / 2 + particle.startY - particle.velocityY * easedProgress
						+ 80 * easedProgress * easedProgress
					let opacity = 1.0 - easedProgress
					let rotation = Angle.degrees(particle.rotationSpeed * elapsed)
					let scale = 1.0 - easedProgress * 0.3

					guard opacity > 0 else { continue }

					context.opacity = opacity
					context.translateBy(x: x, y: y)
					context.rotate(by: rotation)
					context.scaleBy(x: scale, y: scale)

					let rect = CGRect(
						x: -particle.size / 2,
						y: -particle.size / 2,
						width: particle.size,
						height: particle.size
					)
					let path =
						particle.isCircle
						? Path(ellipseIn: rect)
						: Path(roundedRect: rect, cornerRadius: 2)

					context.fill(path, with: .color(particle.color))

					context.scaleBy(x: 1 / scale, y: 1 / scale)
					context.rotate(by: -rotation)
					context.translateBy(x: -x, y: -y)
					context.opacity = 1
				}
			}
		}
		.onAppear {
			particles = (0..<particleCount).map { _ in
				Particle(
					startX: CGFloat.random(in: -120...120),
					startY: CGFloat.random(in: -20...20),
					velocityX: CGFloat.random(in: -60...60),
					velocityY: CGFloat.random(in: 80...200),
					size: CGFloat.random(in: 4...8),
					color: colors.randomElement() ?? .blue,
					lifetime: Double.random(in: 1.5...duration),
					rotationSpeed: Double.random(in: -360...360),
					isCircle: Bool.random()
				)
			}
			startTime = .now
		}
		.allowsHitTesting(false)
	}
}

private struct Particle {
	let startX: CGFloat
	let startY: CGFloat
	let velocityX: CGFloat
	let velocityY: CGFloat
	let size: CGFloat
	let color: Color
	let lifetime: TimeInterval
	let rotationSpeed: Double
	let isCircle: Bool
}
