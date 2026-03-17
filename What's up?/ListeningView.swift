import SwiftUI

enum ListeningVisualization: String, CaseIterable {
	case orb
	case bars

	var label: String {
		switch self {
		case .orb: return "Orb"
		case .bars: return "Bars"
		}
	}
}

struct ListeningView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	@State private var showDevicePicker = false
	@State private var deviceManager = AudioDeviceManager.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("listeningViewCornerRadius") private var cornerRadius = 10.0
	@AppStorage("listeningVisualization") private var visualizationRaw = ListeningVisualization.orb.rawValue
	private let audioManager: AudioManager

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
	}

	private var visualization: ListeningVisualization {
		ListeningVisualization(rawValue: visualizationRaw) ?? .orb
	}

	private var isOrb: Bool {
		visualization == .orb
	}

	private var activeDeviceIcon: String {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return deviceManager.availableDevices.first(where: \.isDefault)?.iconName ?? "mic.fill"
		}
		return deviceManager.availableDevices.first(where: { $0.uid == selectedUID })?.iconName ?? "mic.fill"
	}

	// MARK: - Shared Controls

	private var devicePickerButton: some View {
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
	}

	private var stopButton: some View {
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

	// MARK: - Loading States

	@ViewBuilder
	private var loadingContent: some View {
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
			if whisperKit.isWaitingForModel
				|| whisperKit.isInitializing
				|| whisperKit.isModelLoading
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
		default:
			EmptyView()
		}
	}

	// MARK: - Recording: Bars Layout

	private var barsRecordingContent: some View {
		HStack(spacing: 8) {
			devicePickerButton
			AudioMeterView(levels: audioManager.audioLevels)
			stopButton
		}
	}

	// MARK: - Recording: Orb Layout

	private var orbRecordingContent: some View {
		HStack(spacing: 12) {
			stopButton
			devicePickerButton

			AudioOrbView(
				audioLevel: audioManager.levelMonitor.averageLevel,
				audioBands: audioManager.levelMonitor.levels
			)
			.frame(width: 80, height: 80)
		}
	}

	// MARK: - Content

	@ViewBuilder
	private var contentView: some View {
		if audioManager.currentState == .recording {
			if isOrb {
				orbRecordingContent
			} else {
				barsRecordingContent
			}
		} else {
			loadingContent
		}
	}

	// MARK: - Body

	var body: some View {
		Group {
			if audioManager.currentState == .recording && isOrb {
				orbBody
			} else {
				pillBody
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .devicePickerDismissed)) { _ in
			showDevicePicker = false
		}
	}

	private var orbBody: some View {
		contentView
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.fixedSize(horizontal: true, vertical: false)
	}

	private var pillBody: some View {
		Group {
			let pill = contentView
				.padding(.horizontal, 14)
				.padding(.vertical, 10)
				.fixedSize(horizontal: true, vertical: false)

			if #available(macOS 26.0, *) {
				pill
					.frame(height: 30)
					.glassEffect()
			} else {
				pill
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
	}
}

#Preview {
	ListeningView(audioManager: AudioManager())
		.frame(width: 200, height: 120)
}
