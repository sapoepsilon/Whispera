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
		if selectedUID == AudioDeviceManager.systemDefaultUID || deviceManager.isUsingFallbackInput {
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
			HStack(spacing: 8) {
				ZStack {
					ProgressView()
						.scaleEffect(0.7)
				}
				.frame(width: 20, height: 20)

				Image(systemName: deviceManager.selectedDevice?.iconName ?? "mic.fill")
					.font(.system(size: 11))
					.foregroundColor(.secondary)
			}
		case .transcribing:
			// A load in progress only blocks transcription when no other engine is loaded
			if whisperKit.isWaitingForModel
				|| whisperKit.isInitializing
				|| !whisperKit.isCurrentModelLoaded()
			{
				HStack(spacing: 8) {
					ZStack {
						ProgressView()
							.scaleEffect(0.7)
					}
					.frame(width: 20, height: 20)
					Text(
						whisperKit.isWaitingForModel
							? whisperKit.waitingForModelStatusText
							: (whisperKit.isInitializing
								? whisperKit.initializationStatus
								: (whisperKit.modelSwitchNotice?.title(name: WhisperKitTranscriber.shortModelName)
									?? String(localized: "Loading model...")))
					)
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
			} else {
				HStack(spacing: 8) {
					Text(transcribingText)
						.font(.system(.caption, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
					cancelButton
				}
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
						Image(systemName: audioManager.inputNotice == nil ? activeDeviceIcon : "exclamationmark.triangle.fill")
							.font(.system(size: 11))
							.foregroundColor(audioManager.inputNotice == nil ? nil : .orange)
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
				.help(audioManager.inputNotice ?? String(localized: "Choose microphone"))

				AudioMeterView(levels: audioManager.audioLevels)

				if let notice = whisperKit.modelSwitchNotice,
					let pillText = notice.pillText(name: WhisperKitTranscriber.shortModelName)
				{
					Text(pillText)
						.font(.system(.caption2, design: .rounded))
						.foregroundColor(.secondary)
						.lineLimit(1)
						.help(notice.detail(name: WhisperKitTranscriber.mediumModelName))
				}

				cancelButton

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

	private var transcribingText: String {
		guard let activeModel = whisperKit.modelSwitchNotice?.activeModel else {
			return String(localized: "Transcribing...")
		}
		return String(localized: "Transcribing with \(WhisperKitTranscriber.shortModelName(for: activeModel))...")
	}

	private var cancelButton: some View {
		Button(action: {
			audioManager.cancelRecording()
		}) {
			Image(systemName: "xmark.circle.fill")
				.font(.system(size: 16))
				.foregroundColor(.secondary)
		}
		.buttonStyle(.plain)
		.help("Cancel and discard (Esc)")
		.accessibilityIdentifier("cancelRecordingButton")
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
					.modifier(AdaptiveGlassModifier())
			} else {
				pillContent
					.frame(height: 50)
					.background(
						AdaptiveMaterialBackground(
							style: .ultraThin, shape: RoundedRectangle(cornerRadius: cornerRadius))
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
