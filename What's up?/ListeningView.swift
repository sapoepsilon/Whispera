import SwiftUI

/// Which module the pill is showing. Discrete and Equatable so every animation
/// in the pill can be scoped to it: high-frequency state that must never move
/// the layout (audio levels, the device list) is deliberately absent.
enum PillPhase: Equatable {
	case idle
	case initializing
	case preparingModel(String)
	case transcribing
	case runningRecipe(String)
	case recording
}

/// Discrete, Equatable description of what is on screen in the pill. The pill's
/// size follows from this and nothing else, so there is no
/// measure -> set-frame -> remeasure feedback loop.
struct PillLayout: Equatable {
	var phase: PillPhase
	var controlsOpen: Bool
	var showCancel: Bool
	var typeScale: CGFloat
	/// Affects the pill's width, so it belongs to the layout rather than being
	/// read straight off the device manager.
	var deviceIcon: String

	/// Dynamic-Type scale factor applied to the pill's fixed height so larger
	/// text sizes grow the pill instead of clipping it.
	static func scale(for size: DynamicTypeSize) -> CGFloat {
		switch size {
		case .xSmall, .small, .medium, .large:
			return 1.0
		case .xLarge:
			return 1.06
		case .xxLarge:
			return 1.12
		case .xxxLarge:
			return 1.18
		default:
			return 1.3
		}
	}
}

struct ListeningView: View {
	@State private var whisperKit = WhisperKitTranscriber.shared
	@State private var coordinator = DictationCoordinator.shared
	@State private var showControls = false
	@State private var showCancel = false
	@State private var deviceManager = AudioDeviceManager.shared
	@State private var recipeStore = RecipeStore.shared
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("listeningViewCornerRadius") private var cornerRadius = 10.0
	@AppStorage("whisperaDefaultCommandId") private var defaultCommandId = ""
	private let audioManager: AudioManager
	/// Absent when the pill is embedded in a surface that sizes itself (the
	/// dictation HUD); the floating pill window supplies one.
	private let presenter: PillSizePresenter?

	init(audioManager: AudioManager, presenter: PillSizePresenter? = nil) {
		self.audioManager = audioManager
		self.presenter = presenter
	}

	/// `activeDevice` is the manager's own resolution of "what are we actually
	/// recording from", including the fall back to the system default when the
	/// persisted selection has gone stale - so the pill shows the real device.
	private var activeDeviceIcon: String {
		deviceManager.activeDevice?.iconName ?? "mic.fill"
	}

	private var activeDeviceName: String {
		deviceManager.activeDevice?.name ?? "System Default"
	}

	private var modelStatusText: String {
		if whisperKit.isWaitingForModel { return whisperKit.waitingForModelStatusText }
		if whisperKit.isInitializing { return whisperKit.initializationStatus }
		return "Loading model..."
	}

	private var phase: PillPhase {
		switch audioManager.currentState {
		case .idle:
			return .idle
		case .initializing:
			return .initializing
		case .recording:
			return .recording
		case .transcribing:
			// The post-dictation recipe runs while `isTranscribing` is still true, so
			// it is a phase of this pill rather than a second floating surface.
			if coordinator.isRunning {
				return .runningRecipe(coordinator.runningRecipeName ?? "command")
			}
			if whisperKit.isWaitingForModel
				|| whisperKit.isInitializing
				|| whisperKit.isModelLoading
				|| !whisperKit.isCurrentModelLoaded()
			{
				return .preparingModel(modelStatusText)
			}
			return .transcribing
		}
	}

	private var layout: PillLayout {
		PillLayout(
			phase: phase,
			controlsOpen: showControls,
			showCancel: showCancel,
			typeScale: PillLayout.scale(for: dynamicTypeSize),
			deviceIcon: activeDeviceIcon
		)
	}

	@ViewBuilder
	private var contentView: some View {
		switch layout.phase {
		case .idle:
			EmptyView()
		case .initializing, .recording:
			micLiveRow
		case .preparingModel(let status):
			HStack(spacing: 8) {
				ZStack {
					ProgressView()
						.scaleEffect(0.7)
				}
				.frame(width: 20, height: 20)
				Text(status)
					.font(.system(.caption, design: .rounded))
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
		case .transcribing:
			Text("Transcribing...")
				.font(.system(.caption, design: .rounded))
				.foregroundColor(.secondary)
		case .runningRecipe(let name):
			runningRecipeView(name)
		}
	}

	/// One branch for both mic-live phases, so the device icon keeps its identity
	/// across the initializing/recording flip a device switch causes.
	private var micLiveRow: some View {
		HStack(spacing: 8) {
			if layout.phase == .recording {
				controlsButton
			} else {
				ZStack {
					ProgressView()
						.scaleEffect(0.7)
				}
				.frame(width: 20, height: 20)
			}

			deviceIcon

			if layout.phase == .recording {
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

	/// Which microphone is live. Uses the id + transition swap that the menu bar
	/// status glyph uses (MenuBarView StatusGlyph) rather than
	/// `.contentTransition(.symbolEffect(.replace))`, which never fired here.
	/// Tapping it opens the controls panel straight on the input-device page;
	/// the controls button next to it keeps its root-page toggle.
	private var deviceIcon: some View {
		Button {
			showControls = true
			NotificationCenter.default.post(
				name: .pillControlsToggled,
				object: nil,
				userInfo: PillControlsRouting.userInfo(show: true, page: .input)
			)
		} label: {
			ZStack {
				Image(systemName: layout.deviceIcon)
					.font(.system(size: 11))
					.foregroundColor(.secondary)
					.id(layout.deviceIcon)
					.transition(
						reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
			}
			.animation(reduceMotion ? nil : Motion.iconMorph, value: layout.deviceIcon)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Input device - \(activeDeviceName). Click to switch.")
	}

	/// The post-dictation action, running inside the pill. It takes its final
	/// layout immediately; the window's animated frame growth is what reveals it.
	private func runningRecipeView(_ name: String) -> some View {
		HStack(spacing: 8) {
			ProgressView()
				.scaleEffect(0.7)
			Text("Running \(name)…")
				.font(.system(.caption, design: .rounded))
				.foregroundColor(.secondary)
				.lineLimit(1)
			if layout.showCancel {
				Button("Cancel") { coordinator.cancel() }
					.font(.system(.caption, design: .rounded))
					.buttonStyle(.plain)
					.foregroundColor(.blue)
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
				userInfo: PillControlsRouting.userInfo(show: showControls)
			)
		} label: {
			controlsSwitch
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

	/// The panel's state read as a switch: flipped on while it is presented, off
	/// while it is hidden. Driven by `layout.controlsOpen` — the same state the
	/// panel itself follows, including the `.pillControlsDismissed` reset — so the
	/// glyph cannot say "on" over a closed panel.
	///
	/// Both glyphs stay in the hierarchy and cross-fade. The id + transition swap
	/// the device icon uses removes one view and inserts another, and the removal
	/// runs slightly ahead of the insertion, so the switch visibly blinked out
	/// before it came back. The fixed frame keeps the button's hit area and the
	/// pill's width identical across the flip.
	private var controlsSwitch: some View {
		ZStack {
			switchGlyph("lightswitch.off", shown: !layout.controlsOpen)
			switchGlyph("lightswitch.on", shown: layout.controlsOpen)
		}
		.frame(width: 14, height: 14)
		.animation(reduceMotion ? nil : Motion.iconMorph, value: layout.controlsOpen)
	}

	private func switchGlyph(_ name: String, shown: Bool) -> some View {
		Image(systemName: name)
			.font(.system(size: 11))
			.opacity(shown ? 1 : 0)
			.scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.9))
	}

	private var pillContent: some View {
		contentView
			.transition(.opacity)
			.padding(.horizontal, 14)
			.padding(.vertical, 10)
			.fixedSize(horizontal: true, vertical: false)
			// The module swap is a pure fade at the reveal constant. The content
			// takes its final layout immediately and the window's frame animation
			// uncovers it, so expansion and appearance cannot drift apart.
			.animation(reduceMotion ? nil : Motion.reveal, value: layout.phase)
			.animation(reduceMotion ? nil : Motion.reveal, value: layout.showCancel)
	}

	var body: some View {
		Group {
			if #available(macOS 26.0, *) {
				pillContent
					.frame(height: 30 * layout.typeScale)
					.glassEffect()
			} else {
				pillContent
					.frame(height: 50 * layout.typeScale)
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
		// The pill reports its natural laid-out size and the window assigns it once
		// per real change, mirroring the popover's measurement bridge.
		.onGeometryChange(for: CGSize.self) { proxy in
			proxy.size
		} action: { newSize in
			presenter?.setMeasured(newSize)
		}
		.task(id: coordinator.runningRecipeName) {
			showCancel = false
			guard coordinator.isRunning else { return }
			// Offer a cancel button if the recipe is taking a while.
			try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
			if !Task.isCancelled && coordinator.isRunning { showCancel = true }
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
