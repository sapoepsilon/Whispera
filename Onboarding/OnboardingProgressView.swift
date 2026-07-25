import SwiftUI

struct OnboardingProgressView: View {
	let currentStep: Int
	let totalSteps: Int
	let stepNames: [String]

	/// Seconds for one shimmer sweep, matching the previous repeatForever timing.
	private static let shimmerPeriod: TimeInterval = 2.0

	var body: some View {
		// A repeatForever animation on a gradient's UnitPoint is not something
		// CoreAnimation can drive, so SwiftUI re-evaluated the fill on every
		// display frame — 120/s on ProMotion — for the whole time onboarding was
		// open, on every step. Driving it from a capped schedule instead keeps the
		// sweep identical while cutting the redraws by 4x.
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
			content(
				shimmerOffset: Self.shimmerOffset(at: timeline.date))
		}
	}

	private static func shimmerOffset(at date: Date) -> CGFloat {
		let phase = date.timeIntervalSinceReferenceDate
			.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
		// same -1 ... 2 sweep the animation used
		return -1 + CGFloat(phase) * 3
	}

	private func content(shimmerOffset: CGFloat) -> some View {
		VStack(spacing: 6) {
			GeometryReader { _ in
				HStack(spacing: 3) {
					ForEach(0..<totalSteps, id: \.self) { step in
						RoundedRectangle(cornerRadius: 3)
							.fill(segmentFill(for: step, shimmerOffset: shimmerOffset))
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
	}

	private func segmentFill(for step: Int, shimmerOffset: CGFloat) -> some ShapeStyle {
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
