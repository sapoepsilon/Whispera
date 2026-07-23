import SwiftUI

struct PermissionRowView: View {
	let icon: String
	let title: String
	let description: String
	let isGranted: Bool
	var grantAction: (() -> Void)? = nil

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

			if isGranted {
				Image(systemName: "checkmark.circle.fill")
					.foregroundColor(.green)
					.scaleEffect(checkScale)
			} else if let grantAction {
				Button("Grant", action: grantAction)
					.buttonStyle(SecondaryButtonStyle())
					.controlSize(.small)
			}
		}
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
