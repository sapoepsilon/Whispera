import SwiftUI

/// Which module the pill is showing. Discrete and Equatable so every animation
/// in the pill can be scoped to it: high-frequency state that must never move
/// the layout (audio levels, the device list) is deliberately absent.
enum PillPhase: Equatable {
	case idle
	case initializing
	case preparingModel(String)
	case transcribing
	/// The post-stop finalize pass ("Polishing…"). A phase of this pill because
	/// the pill is the anchor the user watches after stopping; the words window
	/// has already dismissed and must not come back to repeat the status.
	case finalizing(String)
	case runningRecipe(String)
	case recording
}

/// Discrete, Equatable description of what is on screen in the pill. The pill's
/// size follows from this and nothing else, so there is no
/// measure -> set-frame -> remeasure feedback loop.
struct PillLayout: Equatable {
	var phase: PillPhase
	var controlsOpen: Bool
	/// Which page the panel was last opened on, so each control glyph can show
	/// whether it is the one currently presenting.
	var controlsPage: PillPage
	var showCancel: Bool
	var typeScale: CGFloat
	/// Affects the pill's width, so it belongs to the layout rather than being
	/// read straight off the device manager.
	var deviceIcon: String
	/// The armed post-dictation action's identity. Sits beside `deviceIcon` for
	/// the same reason: it is the second glyph in the row, so it is part of what
	/// determines the pill's width.
	var actionIcon: String
	/// Whether a post-dictation action is armed at all, which drives the pill's
	/// tint. Distinct from `actionIcon != noActionGlyph` so the tint has one
	/// authority rather than a glyph comparison.
	var actionArmed: Bool

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
	@State private var live = LiveTranscriptionState.shared
	@State private var coordinator = DictationCoordinator.shared
	@State private var controls = PillControlsState()
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
			// Same shape for the two-pass polish: the words window dismissed at
			// stop, and this pill is the one surface that says the paste is coming.
			if live.isFinalizing {
				return .finalizing(live.finalizingStatusText)
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

	private var postAction: String {
		ListeningPostAction.label(defaultCommandId: defaultCommandId, recipes: recipeStore.recipes)
	}

	private var layout: PillLayout {
		PillLayout(
			phase: phase,
			controlsOpen: controls.isOpen,
			controlsPage: controls.page,
			showCancel: showCancel,
			typeScale: PillLayout.scale(for: dynamicTypeSize),
			deviceIcon: activeDeviceIcon,
			actionIcon: ListeningPostAction.glyph(
				defaultCommandId: defaultCommandId, recipes: recipeStore.recipes),
			actionArmed: ListeningPostAction.isArmed(
				defaultCommandId: defaultCommandId, recipes: recipeStore.recipes)
		)
	}

	@ViewBuilder
	private var contentView: some View {
		switch layout.phase {
		case .idle:
			EmptyView()
		case .initializing, .recording:
			micLiveRow
		case .preparingModel(let status), .finalizing(let status):
			PillStatusRow(indicator: .progress, text: status)
		case .transcribing:
			PillStatusRow(text: "Transcribing...")
		case .runningRecipe(let name):
			runningRecipeView(name)
		}
	}

	/// One branch for both mic-live phases, so the device icon keeps its identity
	/// across the initializing/recording flip a device switch causes.
	private var micLiveRow: some View {
		HStack(spacing: PillSpacing.sm) {
			if layout.phase == .recording {
				actionIcon
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

	/// Icon A: which microphone is live. Uses the id + transition swap that the
	/// menu bar status glyph uses (MenuBarView StatusGlyph) rather than
	/// `.contentTransition(.symbolEffect(.replace))`, which never fired here.
	private var deviceIcon: some View {
		controlIcon(
			glyph: layout.deviceIcon,
			page: .input,
			help: "Input device — \(activeDeviceName). Click to switch."
		)
	}

	/// Icon B: the armed post-dictation action, wearing that action's own glyph
	/// so the pill says what is about to happen to the words. See WHI-50.
	private var actionIcon: some View {
		controlIcon(
			glyph: layout.actionIcon,
			page: .action,
			help: "Post-dictation action — \(postAction). Click to change."
		)
	}

	/// One pill control: a glyph that morphs when its identity changes, on a chip
	/// that lights up while its page is the one the panel is showing. Tapping it
	/// opens that page, or dismisses the panel when it is already there.
	///
	/// Both animations are scoped to this glyph rather than hung off the pill's
	/// root, so a device switch or an action change cannot restart every other
	/// animation in the view.
	private func controlIcon(glyph: String, page: PillPage, help: String) -> some View {
		let active = layout.controlsOpen && layout.controlsPage == page
		return Button {
			toggleControls(page)
		} label: {
			ZStack {
				Image(systemName: glyph)
					.font(.system(size: 11))
					.foregroundColor(.secondary)
					.id(glyph)
					.transition(
						reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
			}
			.frame(width: 14, height: 14)
			.animation(reduceMotion ? nil : Motion.iconMorph, value: glyph)
			.padding(.horizontal, 5)
			.padding(.vertical, 3)
			.background(
				RoundedRectangle(cornerRadius: 5)
					.fill(Color.blue.opacity(active ? 0.18 : 0))
					.animation(reduceMotion ? nil : Motion.iconMorphTint, value: active)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(help)
	}

	/// Open the panel on `page`, or close it when that page is already up. The
	/// panel's own state follows the same notification, so the chip highlight and
	/// what is on screen cannot disagree.
	private func toggleControls(_ page: PillPage) {
		controls.tap(page)
		NotificationCenter.default.post(
			name: .pillControlsToggled,
			object: nil,
			userInfo: controls.routingUserInfo
		)
	}

	/// The post-dictation action, running inside the pill. It takes its final
	/// layout immediately; the window's animated frame growth is what reveals it.
	private func runningRecipeView(_ name: String) -> some View {
		HStack(spacing: PillSpacing.sm) {
			PillStatusRow(indicator: .progress, text: "Running \(name)…")
			if layout.showCancel {
				Button("Cancel") { coordinator.cancel() }
					.font(PillTypography.status)
					.buttonStyle(.plain)
					.foregroundColor(.blue)
			}
		}
	}

	private var pillContent: some View {
		contentView
			.transition(.opacity)
			.padding(.horizontal, PillSpacing.md)
			.padding(.vertical, PillSpacing.sm)
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
			} else {
				pillContent
					.frame(height: 50 * layout.typeScale)
			}
		}
		.pillChrome(cornerRadius: cornerRadius, tinted: layout.actionArmed)
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
			controls.dismissed()
		}
	}
}

/// Resolves what the pill says about the current post-action selection: its
/// label, its glyph, and whether anything is armed at all. Every one of them
/// falls back to "no action" when the selection is unset or points at a command
/// that has since been deleted.
enum ListeningPostAction {
	/// Shown on icon B while nothing is armed. The pill stays neutral here.
	static let noActionGlyph = "nosign"
	/// An armed command whose name matches none of the keywords below. Commands
	/// carry no symbol of their own, so this is the generic "something runs".
	static let genericGlyph = "sparkles"

	/// First match wins, so the more specific words come first.
	private static let glyphKeywords: [(word: String, glyph: String)] = [
		("translat", "globe"),
		("summar", "text.alignleft"),
		("proofread", "wand.and.stars"),
		("grammar", "wand.and.stars"),
		("polish", "wand.and.stars"),
		("email", "envelope"),
		("mail", "envelope"),
		("code", "chevron.left.forwardslash.chevron.right"),
		("checklist", "checklist"),
		("todo", "checklist"),
		("task", "checklist"),
		("meeting", "person.2"),
		("note", "note.text"),
		("question", "questionmark.bubble"),
	]

	static func recipe(defaultCommandId: String, recipes: [Recipe]) -> Recipe? {
		guard !defaultCommandId.isEmpty else { return nil }
		return recipes.first(where: { $0.id == defaultCommandId })
	}

	static func isArmed(defaultCommandId: String, recipes: [Recipe]) -> Bool {
		recipe(defaultCommandId: defaultCommandId, recipes: recipes) != nil
	}

	static func label(defaultCommandId: String, recipes: [Recipe]) -> String {
		guard let recipe = recipe(defaultCommandId: defaultCommandId, recipes: recipes)
		else { return "No action" }
		return recipe.name.isEmpty ? "Untitled" : recipe.name
	}

	static func glyph(defaultCommandId: String, recipes: [Recipe]) -> String {
		guard let recipe = recipe(defaultCommandId: defaultCommandId, recipes: recipes)
		else { return noActionGlyph }
		return glyph(for: recipe)
	}

	static func glyph(for recipe: Recipe) -> String {
		let haystack = "\(recipe.name) \(recipe.description ?? "")".lowercased()
		for entry in glyphKeywords where haystack.contains(entry.word) {
			return entry.glyph
		}
		return genericGlyph
	}
}

#Preview {
	ListeningView(audioManager: AudioManager())
		.frame(width: 200, height: 60)
}
