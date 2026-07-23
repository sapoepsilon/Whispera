import SwiftUI

struct DevicePickerView: View {
	let audioManager: AudioManager
	@State private var deviceManager = AudioDeviceManager.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID

	private let selectedBlue = Color(nsColor: NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0))
	private let unselectedGray = Color(nsColor: NSColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1.0))

	private func isDeviceSelected(_ device: AudioInputDevice) -> Bool {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return device.isDefault
		}
		return device.uid == selectedUID
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				Image(systemName: "mic.fill")
					.font(.system(size: 11))
					.foregroundColor(Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
				Text("Switch Input Device")
					.font(.system(size: 11, weight: .medium, design: .rounded))
					.foregroundColor(Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
			}
			.padding(.bottom, 4)

			Rectangle()
				.fill(Color(nsColor: NSColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1.0)))
				.frame(height: 1)

			Button {
				Task {
					await audioManager.switchInputDevice(to: AudioDeviceManager.systemDefaultUID)
					NotificationCenter.default.post(name: .devicePickerDismissed, object: nil)
				}
			} label: {
				let selected = selectedUID == AudioDeviceManager.systemDefaultUID
				HStack(spacing: 8) {
					Image(systemName: "mic.fill")
						.font(.system(size: 12))
						.frame(width: 20)
						.foregroundColor(selected ? selectedBlue : .secondary)

					Text("System Default")
						.font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded))
						.foregroundColor(selected ? selectedBlue : unselectedGray)
						.lineLimit(1)

					Spacer()

					if selected {
						Image(systemName: "checkmark.circle.fill")
							.font(.system(size: 14))
							.foregroundColor(.blue)
					}
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 5)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(selected ? Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25)) : Color.clear)
				)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			ForEach(deviceManager.availableDevices) { device in
				let selected = isDeviceSelected(device)
				Button {
					Task {
						await audioManager.switchInputDevice(to: device.uid)
						NotificationCenter.default.post(name: .devicePickerDismissed, object: nil)
					}
				} label: {
					HStack(spacing: 8) {
						Image(systemName: device.iconName)
							.font(.system(size: 12))
							.frame(width: 20)
							.foregroundColor(selected ? selectedBlue : .secondary)

						Text(device.name)
							.font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded))
							.foregroundColor(selected ? selectedBlue : unselectedGray)
							.lineLimit(1)

						Spacer()

						if selected {
							Image(systemName: "checkmark.circle.fill")
								.font(.system(size: 14))
								.foregroundColor(.blue)
						}
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 5)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(selected ? Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25)) : Color.clear)
					)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(8)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(Color(nsColor: NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 0.95)))
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.strokeBorder(Color(nsColor: NSColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1.0)), lineWidth: 0.5)
				)
		)
		.shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
		.frame(minWidth: 220)
	}
}
