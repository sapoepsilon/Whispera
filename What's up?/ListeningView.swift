import SwiftUI

struct ListeningView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	@State private var showDevicePicker = false
	@State private var deviceManager = AudioDeviceManager.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("listeningViewCornerRadius") private var cornerRadius = 10.0
	private let audioManager: AudioManager

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
	}

	private var activeDeviceIcon: String {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return deviceManager.availableDevices.first(where: \.isDefault)?.iconName ?? "mic.fill"
		}
		return deviceManager.availableDevices.first(where: { $0.uid == selectedUID })?.iconName ?? "mic.fill"
	}

	@ViewBuilder
	private var contentView: some View {
		switch audioManager.currentState {
		case .idle:
			EmptyView()
		case .initializing:
			HStack(spacing: 6) {
				ProgressView()
					.scaleEffect(0.7)
				Image(systemName: deviceManager.selectedDevice?.iconName ?? "mic.fill")
					.font(.system(size: 11))
					.foregroundColor(.secondary)
			}
		case .transcribing:
			if whisperKit.isWaitingForModel
				|| whisperKit.isInitializing
				|| whisperKit.isModelLoading
				|| !whisperKit.isCurrentModelLoaded()
			{
				HStack(spacing: 6) {
					ProgressView()
						.scaleEffect(0.7)
					Text(
						whisperKit.isWaitingForModel
							? whisperKit.waitingForModelStatusText
							: (whisperKit.isInitializing ? whisperKit.initializationStatus : "Loading model...")
					)
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
			} else {
				Text("Transcribing...")
					.font(.system(.caption, design: .rounded))
					.foregroundColor(.secondary)
			}
		case .recording:
			HStack(spacing: 8) {
				Button {
					showDevicePicker.toggle()
					NotificationCenter.default.post(
						name: .devicePickerToggled,
						object: nil,
						userInfo: ["show": showDevicePicker]
					)
				} label: {
					HStack(spacing: 3) {
						Image(systemName: activeDeviceIcon)
							.font(.system(size: 11))
						Image(systemName: showDevicePicker ? "chevron.up" : "chevron.down")
							.font(.system(size: 8, weight: .semibold))
					}
					.padding(.horizontal, 5)
					.padding(.vertical, 3)
					.background(
						RoundedRectangle(cornerRadius: 5)
							.fill(Color.blue.opacity(0.15))
					)
					.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)

				AudioMeterView(levels: audioManager.audioLevels)

				Button(action: {
					audioManager.toggleRecording()
				}) {
					Image(systemName: "stop.circle.fill")
						.font(.system(size: 16))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help("Stop recording")
			}
		}
	}

	private var pillContent: some View {
		contentView
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.fixedSize(horizontal: true, vertical: false)
	}

	var body: some View {
		Group {
			if #available(macOS 26.0, *) {
				pillContent
					.frame(height: 30)
					.glassEffect()
			} else {
				pillContent
					.frame(height: 50)
					.background(
						RoundedRectangle(cornerRadius: cornerRadius)
							.fill(.ultraThinMaterial)
					)
					.overlay(
						RoundedRectangle(cornerRadius: cornerRadius)
							.strokeBorder(
								LinearGradient(
									colors: [
										Color.blue.opacity(0.3),
										Color.blue.opacity(0.1),
									],
									startPoint: .topLeading,
									endPoint: .bottomTrailing
								),
								lineWidth: 1
							)
					)
					.shadow(color: Color.blue.opacity(0.1), radius: 8, x: 0, y: 2)
					.shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .devicePickerDismissed)) { _ in
			showDevicePicker = false
		}
	}
}

#Preview {
	ListeningView(audioManager: AudioManager())
		.frame(width: 200, height: 60)
}
