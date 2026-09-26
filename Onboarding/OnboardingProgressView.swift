import SwiftUI

struct OnboardingProgressView: View {
	let currentStep: Int
	let totalSteps: Int
	let stepNames: [String]

	@State private var shimmerOffset: CGFloat = -1

	var body: some View {
		VStack(spacing: 6) {
			GeometryReader { geometry in
				let gap: CGFloat = 3
				let totalGaps = CGFloat(totalSteps - 1) * gap
				let segmentWidth = (geometry.size.width - totalGaps) / CGFloat(totalSteps)

				HStack(spacing: gap) {
					ForEach(0..<totalSteps, id: \.self) { step in
						RoundedRectangle(cornerRadius: 3)
							.fill(segmentFill(for: step, width: segmentWidth))
							.frame(height: 6)
					}
				}
			}
			.frame(height: 6)
			.animation(.spring(duration: 0.4, bounce: 0.15), value: currentStep)

			if currentStep < stepNames.count {
				Text(stepNames[currentStep])
					.font(.system(.caption2, design: .rounded))
					.foregroundColor(.secondary)
					.animation(.none, value: currentStep)
			}
		}
		.onAppear {
			withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
				shimmerOffset = 2
			}
		}
	}

	private func segmentFill(for step: Int, width: CGFloat) -> some ShapeStyle {
		if step < currentStep {
			return AnyShapeStyle(Color.blue)
		} else if step == currentStep {
			return AnyShapeStyle(
				LinearGradient(
					colors: [
						Color.blue,
						Color.blue.opacity(0.6),
						Color.blue,
					],
					startPoint: UnitPoint(x: shimmerOffset, y: 0.5),
					endPoint: UnitPoint(x: shimmerOffset + 0.5, y: 0.5)
				)
			)
		} else {
			return AnyShapeStyle(Color.gray.opacity(0.15))
		}
	}
}
