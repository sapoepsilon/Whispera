import SwiftUI

struct OnboardingProgressView: View {
	let currentStep: Int
	let totalSteps: Int
	let stepNames: [String]

	/// Seconds for one shimmer sweep, matching the previous repeatForever timing.
	private static let shimmerPeriod: TimeInterval = 2.0

	var body: some View {
		// The sweep is a capped schedule rather than a repeatForever on the
		// gradient's UnitPoint, which CoreAnimation cannot drive. Scoping the
		// schedule to the one shimmering segment keeps the other four, the label
		// and the containing VStack out of the per-tick invalidation.
		VStack(spacing: 6) {
			HStack(spacing: 3) {
				ForEach(0..<totalSteps, id: \.self) { step in
					TimelineView(
						.animation(minimumInterval: 1.0 / 30.0, paused: step != currentStep)
					) { timeline in
						RoundedRectangle(cornerRadius: 3)
							.fill(
								segmentFill(
									for: step,
									shimmerOffset: Self.shimmerOffset(at: timeline.date))
							)
							.frame(height: 6)
					}
					.frame(maxWidth: .infinity)
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

	private static func shimmerOffset(at date: Date) -> CGFloat {
		let phase = date.timeIntervalSinceReferenceDate
			.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
		// same -1 ... 2 sweep the animation used
		return -1 + CGFloat(phase) * 3
	}

	// hoisted: Color resolves at draw time, so these still track light/dark
	private static let completedFill = AnyShapeStyle(Color.blue)
	private static let upcomingFill = AnyShapeStyle(Color.gray.opacity(0.15))
	private static let shimmerColors: [Color] = [.blue, .blue.opacity(0.6), .blue]

	private func segmentFill(for step: Int, shimmerOffset: CGFloat) -> AnyShapeStyle {
		if step < currentStep {
			return Self.completedFill
		} else if step == currentStep {
			return AnyShapeStyle(
				LinearGradient(
					colors: Self.shimmerColors,
					startPoint: UnitPoint(x: shimmerOffset, y: 0.5),
					endPoint: UnitPoint(x: shimmerOffset + 0.5, y: 0.5)
				)
			)
		} else {
			return Self.upcomingFill
		}
	}
}
