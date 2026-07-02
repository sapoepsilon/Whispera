import SwiftUI

struct ListeningView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	@State private var showControls = false
	@State private var deviceManager = AudioDeviceManager.shared
	@State private var recipeStore = RecipeStore.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("listeningViewCornerRadius") private var cornerRadius = 10.0
	@AppStorage("whisperaDefaultCommandId") private var defaultCommandId = ""
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
							: (whisperKit.isInitializing
								? whisperKit.initializationStatus : "Loading model...")
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
				controlsButton

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

	/// Single pill control that opens the Control-Center-style dropdown
	/// (Input Device + Post-dictation Action). See WHI-50.
	private var controlsButton: some View {
		Button {
			showControls.toggle()
			NotificationCenter.default.post(
				name: .pillControlsToggled,
				object: nil,
				userInfo: ["show": showControls]
			)
		} label: {
			HStack(spacing: 3) {
				Image(systemName: "switch.2")
					.font(.system(size: 11))
				Image(systemName: showControls ? "chevron.up" : "chevron.down")
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
		.help("Input device & post-dictation action — \(ListeningPostAction.label(defaultCommandId: defaultCommandId, recipes: recipeStore.recipes))")
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
		.onReceive(NotificationCenter.default.publisher(for: .pillControlsDismissed)) { _ in
			showControls = false
		}
	}
}

/// Resolves the human-readable label for the current post-action selection.
/// Falls back to "No action" when unset or pointing at a deleted command.
enum ListeningPostAction {
	static func label(defaultCommandId: String, recipes: [Recipe]) -> String {
		guard !defaultCommandId.isEmpty,
			let recipe = recipes.first(where: { $0.id == defaultCommandId })
		else { return "No action" }
		return recipe.name.isEmpty ? "Untitled" : recipe.name
	}
}

#Preview {
	ListeningView(audioManager: AudioManager())
		.frame(width: 200, height: 60)
}
