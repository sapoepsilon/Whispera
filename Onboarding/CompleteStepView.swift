import SwiftUI

struct CompleteStepView: View {
	@AppStorage("globalShortcut") private var globalShortcut = "⌥⌘R"
	@State private var showContent = false
	@State private var showCards = [false, false, false]
	@State private var floatOffset: CGFloat = 0

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
				.opacity(showContent ? 1 : 0)

			VStack(spacing: 24) {
				Spacer()

				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 80, height: 80)
					.clipShape(RoundedRectangle(cornerRadius: 18))
					.offset(y: floatOffset)
					.scaleEffect(showContent ? 1 : 0.5)
					.opacity(showContent ? 1 : 0)

				VStack(spacing: 8) {
					Text("You're Ready")
						.font(.system(.largeTitle, design: .rounded, weight: .bold))

					Text("Whispera is configured and ready to use.")
						.font(.body)
						.foregroundColor(.secondary)
				}
				.opacity(showContent ? 1 : 0)
				.offset(y: showContent ? 0 : 10)

				VStack(spacing: 10) {
					ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
						tipCard(icon: tip.icon, title: tip.title, description: tip.description)
							.scaleEffect(showCards[index] ? 1 : 0.9)
							.opacity(showCards[index] ? 1 : 0)
					}
				}
				.padding(.top, 8)

				Spacer()
			}
		}
		.onAppear {
			withAnimation(.spring(duration: 0.6, bounce: 0.25)) {
				showContent = true
			}
			for i in 0..<3 {
				withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(0.3 + Double(i) * 0.15)) {
					showCards[i] = true
				}
			}
			withAnimation(
				.easeInOut(duration: 2.0)
				.repeatForever(autoreverses: true)
				.delay(0.5)
			) {
				floatOffset = -6
			}
		}
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
