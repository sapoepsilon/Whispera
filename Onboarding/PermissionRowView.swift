import SwiftUI

struct PermissionRowView: View {
	let icon: String
	let title: String
	let description: String
	let isGranted: Bool

	@State private var checkScale: CGFloat = 1.0

	var body: some View {
		HStack(spacing: 16) {
			ZStack {
				Circle()
					.fill(isGranted ? .green.opacity(0.2) : .gray.opacity(0.2))
					.frame(width: 40, height: 40)

				Image(systemName: icon)
					.font(.system(size: 18))
					.foregroundColor(isGranted ? .green : .gray)
			}

			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.system(.subheadline, design: .rounded, weight: .medium))
				Text(description)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()

			Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
				.foregroundColor(isGranted ? .green : .gray)
				.scaleEffect(checkScale)
		}
		.padding()
		.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
		.onChange(of: isGranted) { wasGranted, nowGranted in
			if !wasGranted && nowGranted {
				checkScale = 0.3
				withAnimation(.spring(duration: 0.4, bounce: 0.5)) {
					checkScale = 1.0
				}
			}
		}
	}
}
