import SwiftUI

struct CompleteStepView: View {
	@AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"
	@State private var floatStart = Date()

	private static let floatDistance: CGFloat = -6
	private static let floatLeg: TimeInterval = 2.0
	private static let floatDelay: TimeInterval = 0.5

	private var tips: [(icon: String, title: String, description: String)] {
		[
			("keyboard", "Press \(globalShortcut) anywhere", "Start recording from any app"),
			("menubar.arrow.up.rectangle", "Menu bar access", "Find Whispera in your menu bar"),
			("lock.shield", "Private by design", "All processing stays on your Mac"),
		]
	}

	var body: some View {
		ZStack {
			ConfettiView()
				.frame(maxWidth: .infinity, maxHeight: .infinity)

			VStack(spacing: 24) {
				Spacer()

				// a repeatForever offset holds SwiftUI's update loop at full display
				// refresh for as long as this step is open; the 12pt round trip
				// over 4s moves under a third of a pixel per 30Hz tick, so a
				// capped schedule is the same motion at a quarter of the ticks
				TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
					Image(nsImage: NSApp.applicationIconImage)
						.resizable()
						.frame(width: 80, height: 80)
						.clipShape(RoundedRectangle(cornerRadius: 18))
						.offset(
							y: Self.floatOffset(
								at: timeline.date.timeIntervalSince(floatStart)))
				}
				.frame(width: 80, height: 80)

				VStack(spacing: 8) {
					Text("You're Ready")
						.font(.system(.largeTitle, design: .rounded, weight: .bold))

					Text("Whispera is configured and ready to use.")
						.font(.body)
						.foregroundColor(.secondary)
				}

				VStack(spacing: 10) {
					ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
						tipCard(icon: tip.icon, title: tip.title, description: tip.description)
					}
				}
				.padding(.top, 8)

				Spacer()
			}
		}
	}

	// UnitCurve.easeInOut is the same cubic bezier Animation.easeInOut uses and is
	// symmetric, so the autoreversing leg needs no special case.
	private static func floatOffset(at elapsed: TimeInterval) -> CGFloat {
		let t = max(0, elapsed - floatDelay)
		let cycle = (t / floatLeg).truncatingRemainder(dividingBy: 2)
		let leg = cycle <= 1 ? cycle : 2 - cycle
		return floatDistance * CGFloat(UnitCurve.easeInOut.value(at: leg))
	}

	private func tipCard(icon: String, title: String, description: String) -> some View {
		HStack(spacing: 12) {
			ZStack {
				Circle()
					.fill(Color.blue.opacity(0.1))
					.frame(width: 36, height: 36)
				Image(systemName: icon)
					.font(.system(size: 14, weight: .semibold))
					.foregroundColor(.blue)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.system(.subheadline, design: .rounded, weight: .medium))
				Text(description)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()
		}
		.padding(12)
		.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
	}
}
