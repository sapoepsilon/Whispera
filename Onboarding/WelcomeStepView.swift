import SwiftUI

struct WelcomeStepView: View {
	@State private var animateRings = false
	@State private var showContent = false
	@State private var showPills = [false, false, false]

	private let pills: [(icon: String, label: String)] = [
		("waveform", "On-device"),
		("lock.fill", "Private"),
		("checkmark.seal", "Accurate"),
	]

	var body: some View {
		VStack(spacing: 32) {
			Spacer()

			ZStack {
				ForEach(0..<3, id: \.self) { index in
					Circle()
						.stroke(
							Color.blue.opacity(0.3 - Double(index) * 0.1),
							lineWidth: 2 - CGFloat(index) * 0.5
						)
						.frame(
							width: 100 + CGFloat(index) * 30,
							height: 100 + CGFloat(index) * 30
						)
						.scaleEffect(animateRings ? 1.0 + CGFloat(index + 1) * 0.05 : 1.0)
						.opacity(animateRings ? 0.6 : 1.0)
						.animation(
							.easeInOut(duration: 2.0 + Double(index) * 0.5)
								.repeatForever(autoreverses: true)
								.delay(Double(index) * 0.3),
							value: animateRings
						)
				}

				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 80, height: 80)
					.clipShape(RoundedRectangle(cornerRadius: 18))
			}
			.opacity(showContent ? 1 : 0)
			.scaleEffect(showContent ? 1 : 0.8)

			VStack(spacing: 8) {
				Text("Whispera")
					.font(.system(.largeTitle, design: .rounded, weight: .bold))

				Text("Your voice, transcribed locally")
					.font(.title3)
					.foregroundColor(.secondary)
			}
			.opacity(showContent ? 1 : 0)
			.offset(y: showContent ? 0 : 10)

			HStack(spacing: 12) {
				ForEach(Array(pills.enumerated()), id: \.offset) { index, pill in
					HStack(spacing: 6) {
						Image(systemName: pill.icon)
							.font(.system(size: 10, weight: .semibold))
						Text(pill.label)
							.font(.system(.caption, design: .rounded, weight: .medium))
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.background(.ultraThinMaterial, in: Capsule())
					.overlay(Capsule().stroke(Color.blue.opacity(0.15), lineWidth: 1))
					.scaleEffect(showPills[index] ? 1 : 0.5)
					.opacity(showPills[index] ? 1 : 0)
				}
			}

			Spacer()
		}
		.onAppear {
			withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
				showContent = true
			}
			animateRings = true
			for i in 0..<3 {
				withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.4 + Double(i) * 0.12)) {
					showPills[i] = true
				}
			}
		}
	}
}
