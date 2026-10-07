import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
	@Bindable var audioManager: AudioManager
	var whisperKit = WhisperKitTranscriber.shared
	@AppStorage(ShortcutDefaults.dictationKey) private var shortcutKey = ShortcutDefaults.dictation
	@AppStorage("selectedLanguage") private var selectedLanguage = Constants.defaultLanguageName
	@AppStorage("materialStyle") private var materialStyleRaw = MaterialStyle.default.rawValue

	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	// MARK: - Injected Dependencies
	@State var permissionManager: PermissionManager
	@ObservedObject var softwareUpdater: SoftwareUpdater
	@Bindable var fileTranscriptionManager: FileTranscriptionManager
	@Bindable var networkDownloader: NetworkFileDownloader
	@Bindable var queueManager: TranscriptionQueueManager

	// MARK: - File Drop Handler
	// Constructed once in the AppDelegate and injected so drag/drop is live from
	// frame 0 with no per-open reallocation.
	let fileDropHandler: FileDropHandler

	// MARK: - Status-item menu mirror
	// The header "…" overflow menu is built from the same ordered command list the
	// status-item right-click NSMenu uses, so the two surfaces cannot drift.
	let menuEntries: [StatusMenuEntry]
	let performMenuAction: @MainActor (StatusMenuAction) -> Void

	// The SwiftUI Settings-scene open action. Registered with the AppDelegate so
	// every settings entry point can try the native scene first and fall back to
	// the retained window when the action silently no-ops.
	@Environment(\.openSettings) private var openSettings
	let registerOpenSettings: (@escaping @MainActor () -> Void) -> Void

	// Receives the content's measured height; the AppDelegate turns it into an
	// animated popover.contentSize change.
	let presenter: PopoverPresenter

	// MARK: - Toast
	// The single success/error language for the whole popover. Owns its own state
	// and dismiss timers (constructed once in the AppDelegate and injected) so a
	// pending auto-dismiss never invalidates this view's body.
	let toastCenter: ToastCenter

	// MARK: - Transient view state
	// Whether the user dismissed the update row this session.
	@State private var updateRowDismissed = false

	private var materialStyle: MaterialStyle {
		MaterialStyle(rawValue: materialStyleRaw)
	}

	// Discrete, derived description of which modules are on screen. Equatable so
	// the presenter only recomputes height on genuine state changes.
	private var layout: PopoverLayout {
		let permissionRows =
			(permissionManager.microphonePermissionGranted ? 0 : 1)
			+ (permissionManager.accessibilityPermissionGranted ? 0 : 1)
		return PopoverLayout(
			updateVisible: softwareUpdater.availableUpdateVersion != nil && !updateRowDismissed,
			permissionRows: permissionRows,
			modelPreparing: !whisperKit.isInitialized || whisperKit.downloadBlocksDictation,
			modelDownloading: whisperKit.isDownloadingModel,
			hasResult: audioManager.transcriptionError == nil && audioManager.lastTranscription != nil,
			typeScale: PopoverLayout.scale(for: dynamicTypeSize)
		)
	}

	var body: some View {
		ScrollView(.vertical) {
			content
		}
		.scrollDisabled(!presenter.scrolls)
		.scrollIndicators(presenter.scrolls ? .automatic : .never)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(AdaptiveMaterialBackground(style: materialStyle))
		.overlay(dropZoneOverlay)
		.onAppear { registerOpenSettings { openSettings() } }
		.onChange(of: audioManager.transcriptionError) { _, newValue in
			if let error = newValue {
				// Routine notices stay in the menu bar; failures, and notices nothing else showed, notify
				toastCenter.show(
					error, type: .error, notifyWhenHidden: audioManager.transcriptionErrorNotifiesWhenHidden)
			}
		}
		.onDrop(
			of: [.fileURL, .url, .text, .plainText],
			isTargeted: Binding(
				get: { fileDropHandler.isDragging },
				set: { isDragging in
					if isDragging {
						fileDropHandler.dragEntered()
					} else {
						fileDropHandler.dragExited()
					}
				}
			)
		) { providers in
			let dropHandler = fileDropHandler

			let info = DropInfo(providers: providers)
			let canAccept = dropHandler.canAccept(info)
			guard canAccept else { return false }

			// Perform async operation in the background without blocking UI
			Task { @MainActor in
				// Reset drag state immediately to update UI
				dropHandler.dragExited()

				// Handle drop in background
				let _ = await dropHandler.handleDrop(info)
			}

			return true
		}
		.onReceive(NotificationCenter.default.publisher(for: .fileTranscriptionError)) { notification in
			guard let message = notification.userInfo?["message"] as? String else { return }
			toastCenter.show(message, type: .error)
		}
		.onReceive(NotificationCenter.default.publisher(for: .fileTranscriptionSuccess)) {
			notification in
			guard let message = notification.userInfo?["message"] as? String else { return }
			toastCenter.show(message, type: .success)
		}
	}

	private var content: some View {
		VStack(spacing: 0) {

			// Main content
			VStack(spacing: 16) {
				if layout.updateVisible {
					UpdateRow(
						softwareUpdater: softwareUpdater,
						onDismiss: { updateRowDismissed = true }
					)
				}

				SecureInputWarningBanner()

				AppNoticeBanners()

				HeaderLine(
					audioManager: audioManager,
					whisperKit: whisperKit,
					permissionManager: permissionManager,
					fileTranscriptionManager: fileTranscriptionManager,
					networkDownloader: networkDownloader,
					shortcutKey: ShortcutDisplay.text(for: shortcutKey),
					menuEntries: menuEntries,
					performMenuAction: performMenuAction
				)

				// Blocking conditions stack as 0..n actionable rows in priority order:
				// missing permissions (deep-linked per pane) then model preparation.
				if layout.needsPermissions || layout.modelPreparing || layout.modelDownloading {
					FixItStack(
						permissionManager: permissionManager,
						whisperKit: whisperKit
					)
					.transition(
						reduceMotion
							? .opacity
							: .move(edge: .top).combined(with: .opacity))
				}

				if whisperKit.isInitialized, let notice = whisperKit.modelSwitchNotice {
					ModelSwitchNoticeRow(notice: notice, showsTitle: !whisperKit.isDownloadingModel)
				}

				DictateLane(
					audioManager: audioManager,
					shortcutKey: ShortcutDisplay.text(for: shortcutKey),
					selectedLanguage: selectedLanguage,
					isBlocked: layout.needsPermissions || layout.modelPreparing
				)

				HStack(spacing: 8) {
					Button {
						HistoryWindowController.shared.show()
					} label: {
						Label("History", systemImage: "clock.arrow.circlepath")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(SecondaryButtonStyle())
					.accessibilityIdentifier("menuBarHistoryButton")

					Button(action: copyLastTranscript) {
						Label("Copy Last", systemImage: "doc.on.doc")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(SecondaryButtonStyle())
					.help("Copy the most recent transcript to the clipboard")
					.accessibilityIdentifier("menuBarCopyLastButton")
				}

				// Single compact lane for the file journey: Drop (the whole popover is
				// the target) or Browse (NSOpenPanel), and an active summary that opens
				// the Activity window. Replaces the transitional queue status card.
				FileLane(
					queueManager: queueManager,
					onOpenActivity: { performMenuAction(.activity) }
				)
			}
			.padding(.horizontal, 20)
			.padding(.top, 14)
			.padding(.bottom, 20)
			// Structural animation only: when a size-affecting module (update row,
			// Fix-It stack) enters or leaves, ITS transition runs and the sibling
			// lanes glide to their new positions. Scoped to these two values so
			// unrelated state (recording, mode, results) never animates this stack.
			.animation(
				reduceMotion ? nil : Motion.structural,
				value: layout.updateVisible
			)
			.animation(
				reduceMotion ? nil : Motion.structural,
				value: layout.needsPermissions || layout.modelPreparing || layout.modelDownloading)

			// Result glance: only when there is a real transcription (errors route to
			// the toast, never the glance). The card takes its final layout
			// immediately and the popover's animated frame growth reveals it -
			// one animation, so expansion and appearance cannot drift apart. The
			// short fade blooms the card in as the frame uncovers it.
			Group {
				if audioManager.transcriptionError == nil,
					let transcription = audioManager.lastTranscription
				{
					ResultGlance(
						text: transcription,
						onDismiss: { audioManager.lastTranscription = nil }
					)
					.transition(.opacity)
				}
			}
			.animation(reduceMotion ? nil : Motion.reveal, value: layout.hasResult)

			ToastOverlay(toastCenter: toastCenter)

		}
		.frame(width: PopoverMetrics.width)
		.onGeometryChange(for: CGFloat.self) { proxy in
			proxy.size.height
		} action: { newHeight in
			presenter.setMeasured(newHeight, visibleScreenHeight: NSScreen.main?.visibleFrame.height)
		}
	}

	/// Clipboard restore puts the previous clipboard back after pasting, so this is the quick
	/// way to paste a dictation again.
	private func copyLastTranscript() {
		let actions = RemoteHistoryActions.live
		guard let text = actions.lastTranscript(audioManager) else {
			toastCenter.show(String(localized: "No transcript yet"), type: .error)
			return
		}
		actions.copyToClipboard(text)
		toastCenter.show(String(localized: "Copied the last transcript"), type: .success)
	}

	// MARK: - Drag & Drop UI

	@ViewBuilder
	private var dropZoneOverlay: some View {
		if fileDropHandler.isDragging {
			let dropHandler = fileDropHandler
			RoundedRectangle(cornerRadius: 12)
				.fill(dropHandler.dropZoneColor)
				.stroke(dropHandler.isValidDrop ? .green : .red, lineWidth: 2)
				.overlay(
					VStack(spacing: 12) {
						Image(systemName: dropHandler.dropZoneIcon)
							.font(.system(size: 32))
							.foregroundColor(dropHandler.isValidDrop ? .green : .red)

						Text(dropHandler.dropZoneText)
							.font(.headline)
							.foregroundColor(dropHandler.isValidDrop ? .green : .red)
							.multilineTextAlignment(.center)

						if dropHandler.isValidDrop && dropHandler.draggedItemsCount > 0 {
							Text(
								dropHandler.draggedItemsCount == 1
									? String(localized: "1 item")
									: String(localized: "\(dropHandler.draggedItemsCount) items")
							)
							.font(.caption)
							.foregroundColor(.secondary)
						}
					}
				)
				.allowsHitTesting(false)
		}
	}
}

// MARK: - File lane

enum QueueSummary {
	static func text(total: Int, processing: Int) -> String {
		switch (total == 1, processing > 0) {
		case (true, true): return String(localized: "1 file · \(processing) processing")
		case (true, false): return String(localized: "1 file")
		case (false, true): return String(localized: "\(total) files · \(processing) processing")
		case (false, false): return String(localized: "\(total) files")
		}
	}
}

// The single compact row for the file journey. Idle: a Browse affordance backed by
// an NSOpenPanel plus the always-live popover drop target. Active: a "N files · M
// processing" summary with a 2pt determinate mini-bar that opens the Activity
// window on tap. A slim rule separates it from the dictation controls above.
struct FileLane: View {
	@Bindable var queueManager: TranscriptionQueueManager
	let onOpenActivity: () -> Void

	private var isActive: Bool { !queueManager.items.isEmpty }

	private var summary: String {
		QueueSummary.text(total: queueManager.items.count, processing: queueManager.processingItems.count)
	}

	var body: some View {
		VStack(spacing: 12) {
			Divider()

			Button(action: primaryAction) {
				HStack(spacing: 8) {
					Image(systemName: "doc.badge.arrow.up")
						.font(.system(size: 14))
						.foregroundStyle(.secondary)

					if isActive {
						Text(summary)
							.font(.caption)
							.foregroundStyle(.primary)
							.lineLimit(1)
							.truncationMode(.middle)

						Spacer(minLength: 8)

						ProgressView(value: queueManager.overallProgress)
							.frame(width: 48)
							.frame(height: 2)

						Image(systemName: "chevron.right")
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(.secondary)
					} else {
						Text("Transcribe a file")
							.font(.caption)
							.foregroundStyle(.primary)

						Spacer(minLength: 8)

						Text("Browse…")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel(isActive ? Text(summary) : Text("Transcribe a file"))
			.accessibilityHint(isActive ? Text("Open Transcription Activity") : Text("Drop a file on the menu, or click to browse"))
			.help(isActive ? String(localized: "Open Transcription Activity") : String(localized: "Browse for a file to transcribe"))
		}
	}

	private func primaryAction() {
		if isActive {
			onOpenActivity()
		} else {
			browse()
		}
	}

	private func browse() {
		let panel = NSOpenPanel()
		panel.title = String(localized: "Select Audio or Video Files to Transcribe")
		panel.message = String(localized: "Choose audio or video files for transcription")
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		panel.allowedContentTypes = [.audio, .movie]

		guard panel.runModal() == .OK else { return }
		let urls = panel.urls
		guard !urls.isEmpty else { return }

		queueManager.addFiles(urls)
		onOpenActivity()
	}
}

// MARK: - Fix-It stack
// Blocking conditions render as 0..n actionable cards in priority order. Missing
// permissions come first, each deep-linking to its own System Settings pane so a
// both-missing state is fully remediable; model preparation follows as a single
// folded status with two distinct sub-states: Downloading (network, cancellable,
// determinate bar) and Loading (non-cancellable, one small indeterminate spinner).
// At most one indeterminate spinner is mounted across the whole popover.
struct FixItStack: View {
	var permissionManager: PermissionManager
	var whisperKit: WhisperKitTranscriber

	var body: some View {
		VStack(spacing: 12) {
			if !permissionManager.microphonePermissionGranted {
				FixItRow(
					title: String(localized: "Microphone access is off"),
					actionTitle: String(localized: "Open Microphone Settings"),
					action: { permissionManager.openMicrophoneSettings() }
				)
			}

			if !permissionManager.accessibilityPermissionGranted {
				FixItRow(
					title: String(localized: "Accessibility access is off"),
					actionTitle: String(localized: "Open Accessibility Settings"),
					action: { permissionManager.openAccessibilitySettings() }
				)
			}

			if whisperKit.isDownloadingModel {
				ModelDownloadingRow(whisperKit: whisperKit)
			} else if !whisperKit.isInitialized {
				ModelLoadingRow(whisperKit: whisperKit)
			}
		}
	}
}

// Actionable card for a single missing permission: a warning line plus a
// full-width deep-link button into the specific System Settings pane.
struct FixItRow: View {
	let title: String
	let actionTitle: String
	let action: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.orange)

				Text(title)
					.font(.system(.subheadline, design: .rounded, weight: .medium))
					.foregroundColor(.primary)

				Spacer()
			}

			Button(action: action) {
				Text(actionTitle)
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(SecondaryButtonStyle())
		}
		.padding(12)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
	}
}

// Downloading sub-state: network transfer with a determinate bar and a Cancel
// that aborts it. The percent text is the single progress indicator (no ring).
struct ModelDownloadingRow: View {
	var whisperKit: WhisperKitTranscriber

	private var modelName: String {
		whisperKit.downloadingModelName?
			.replacingOccurrences(of: "openai_whisper-", with: "") ?? String(localized: "model")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "arrow.down.circle.fill")
					.foregroundColor(.orange)

				Text("Downloading model")
					.font(.system(.subheadline, design: .rounded, weight: .medium))
					.foregroundColor(.primary)

				Spacer()

				Text("\(modelName) \(Int((whisperKit.downloadProgress * 100).rounded()))%")
					.font(.system(.caption, design: .rounded))
					.foregroundColor(.secondary)
					.monospacedDigit()
			}

			HStack(spacing: 8) {
				ProgressView(value: whisperKit.downloadProgress)
					.frame(height: 4)

				// The load after the transfer cannot be interrupted, so Cancel goes away with it
				if whisperKit.isModelDownloadCancellable {
					Button("Cancel") {
						whisperKit.cancelModelDownload()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
			}
		}
		.padding(12)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
	}
}

// Loading / prewarming sub-state: non-cancellable, so no Cancel button. This is
// the only indeterminate spinner mounted anywhere in the popover.
struct ModelLoadingRow: View {
	var whisperKit: WhisperKitTranscriber

	var body: some View {
		HStack(spacing: 10) {
			ProgressView()
				.controlSize(.small)

			VStack(alignment: .leading, spacing: 2) {
				Text("Loading model…")
					.font(.system(.subheadline, design: .rounded, weight: .medium))
					.foregroundColor(.primary)

				Text(whisperKit.initializationStatus)
					.font(.system(.caption2, design: .rounded))
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.tail)
			}

			Spacer()
		}
		.padding(12)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
	}
}

// MARK: - Status model
// The single resolver for the HeaderLine: color, glyph, title, and subtitle share
// one priority order (file operations first, then permissions, model, recording)
// so the accent, icon, and text can never diverge. It deliberately omits the live
// recording duration; that ticks in an isolated RecordingDurationLabel leaf.
struct MenuBarStatusModel {
	let color: Color
	let systemImage: String
	let title: String
	let subtitle: String

	@MainActor
	init(
		audioManager: AudioManager,
		whisperKit: WhisperKitTranscriber,
		permissionManager: PermissionManager,
		fileTranscriptionManager: FileTranscriptionManager,
		networkDownloader: NetworkFileDownloader,
		shortcutKey: String
	) {
		let phase = MenuBarStatusPhase.resolve(
			downloadingFile: networkDownloader.isDownloading,
			transcribingFile: fileTranscriptionManager.isTranscribing,
			needsPermissions: permissionManager.needsPermissions,
			recording: audioManager.isSessionActive,
			downloadingModel: whisperKit.isDownloadingModel,
			transcribing: audioManager.isTranscribing)

		switch phase {
		case .downloadingFile:
			color = .orange
			systemImage = "arrow.down.circle.fill"
			title = String(localized: "Downloading File...")
			subtitle = String(localized: "Progress: \(Int(networkDownloader.downloadProgress * 100))%")
		case .transcribingFile:
			color = .blue
			systemImage = "waveform"
			title = String(localized: "Transcribing File...")
			if let filename = fileTranscriptionManager.currentFileName {
				subtitle = String(localized: "Processing: \(filename)")
			} else {
				subtitle = String(localized: "Processing file...")
			}
		case .needsPermissions:
			color = .orange
			systemImage = "exclamationmark.triangle.fill"
			title = String(localized: "Permissions Required")
			subtitle = String(localized: "Grant required permissions to continue")
		case .recording:
			color = .red
			systemImage = "mic.fill"
			title = String(localized: "Recording...")
			subtitle = String(localized: "\(shortcutKey) to stop")
		case .downloadingModel:
			color = .orange
			systemImage = "arrow.down.circle.fill"
			title = String(localized: "Downloading Model...")
			if let model = whisperKit.downloadingModelName {
				let cleanName = model.replacingOccurrences(of: "openai_whisper-", with: "")
				subtitle = String(localized: "Installing \(cleanName) model")
			} else {
				subtitle = String(localized: "Installing Whisper model")
			}
		case .transcribing:
			let translating = audioManager.enableTranslation
			color = .blue
			systemImage = "waveform"
			title = translating ? String(localized: "Translating...") : String(localized: "Transcribing...")
			subtitle = translating ? String(localized: "Converting speech to English") : String(localized: "Converting speech to text")
		case .ready:
			color = .green
			systemImage = "checkmark.circle.fill"
			title = String(localized: "Ready")
			subtitle = String(localized: "Press \(shortcutKey) to dictate")
		}
	}
}

/// One priority order for the header's color, glyph and text. A recording that is running outranks
/// an earlier dictation still transcribing, because that is what the stop shortcut acts on.
enum MenuBarStatusPhase: Equatable {
	case downloadingFile, transcribingFile, needsPermissions, recording, downloadingModel, transcribing, ready

	static func resolve(
		downloadingFile: Bool, transcribingFile: Bool, needsPermissions: Bool, recording: Bool,
		downloadingModel: Bool, transcribing: Bool
	) -> MenuBarStatusPhase {
		if downloadingFile { return .downloadingFile }
		if transcribingFile { return .transcribingFile }
		if needsPermissions { return .needsPermissions }
		if recording { return .recording }
		if downloadingModel { return .downloadingModel }
		if transcribing { return .transcribing }
		return .ready
	}
}

/// What the popover's primary button does. Stop stays available while a recording runs even if an
/// earlier dictation is still transcribing; the spinner only shows when nothing is capturing.
enum RecordButtonMode: Equatable {
	case start, stop, transcribing

	static func resolve(capturing: Bool, transcribing: Bool) -> RecordButtonMode {
		if capturing { return .stop }
		return transcribing ? .transcribing : .start
	}

	func isEnabled(blocked: Bool) -> Bool {
		switch self {
		case .stop: return true
		case .transcribing: return false
		case .start: return !blocked
		}
	}
}

// MARK: - Result Glance

// The last dictation, shown selectable with a Copy affordance that flips to a
// "Copied" confirmation, an Expand toggle that reveals the full text in a bounded
// internal ScrollView (so the popover grows once instead of clipping), and a
// dismiss that clears the result. Auto-clears when the next recording starts
// (AudioManager clears lastTranscription in beginRecording).
struct ResultGlance: View {
	let text: String
	let onDismiss: () -> Void

	@State private var didCopy = false
	@State private var copyResetTask: Task<Void, Never>?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 12) {
				Text("Last dictation")
					.font(.caption)
					.foregroundColor(.secondary)

				Spacer()

				Button(action: copy) {
					HStack(spacing: 3) {
						Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
						Text(didCopy ? String(localized: "Copied") : String(localized: "Copy"))
					}
					.font(.caption)
				}
				.buttonStyle(.plain)
				.foregroundColor(didCopy ? .green : .blue)
				.help("Copy to Clipboard")

				Button(action: onDismiss) {
					Image(systemName: "xmark")
						.font(.caption)
				}
				.buttonStyle(.plain)
				.foregroundColor(.secondary)
				.help("Dismiss")
			}

			Text(text)
				.font(.system(.body, design: .rounded))
				.foregroundColor(.primary)
				.lineLimit(3)
				.multilineTextAlignment(.leading)
				.textSelection(.enabled)
		}
		.padding(12)
		.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(.blue.opacity(0.3), lineWidth: 1)
		)
		.padding(.horizontal, 20)
		.padding(.bottom, 12)
	}

	private func copy() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		didCopy = true
		copyResetTask?.cancel()
		copyResetTask = Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			if !Task.isCancelled {
				didCopy = false
			}
		}
	}
}

// MARK: - Recording Duration Label

// Isolated leaf: the per-second tick invalidates only this ~20pt label via
// TimelineView, never the surrounding popover body or the status card.
struct RecordingDurationLabel: View {
	let audioManager: AudioManager

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1.0)) { _ in
			Text(audioManager.formattedRecordingDuration())
				.font(.system(.body, design: .rounded, weight: .medium))
				.monospacedDigit()
		}
	}
}

// MARK: - Button Styles
// Semantic color tokens (design-language.md > Color Palette). Mapped to the
// system colors so they keep adapting to light/dark and increased-contrast.
extension Color {
	static let recordingAccent = Color.red
	static let primaryAction = Color.blue
}

// Shared button geometry so Primary and Secondary stack without seams.
private enum ButtonMetrics {
	static let height: CGFloat = 40
	static let cornerRadius: CGFloat = 10
}

struct PrimaryButtonStyle: ButtonStyle {
	let isRecording: Bool

	func makeBody(configuration: Configuration) -> some View {
		PrimaryButtonBody(isRecording: isRecording, configuration: configuration)
	}

	private struct PrimaryButtonBody: View {
		let isRecording: Bool
		let configuration: ButtonStyleConfiguration
		@Environment(\.isEnabled) private var isEnabled
		@Environment(\.accessibilityReduceMotion) private var reduceMotion

		var body: some View {
			configuration.label
				.padding(.horizontal, 16)
				.frame(minHeight: ButtonMetrics.height)
				.font(.system(.body, design: .rounded, weight: .medium))
				.foregroundColor(.white)
				.background(
					RoundedRectangle(cornerRadius: ButtonMetrics.cornerRadius)
						.fill(isRecording ? Color.recordingAccent : Color.primaryAction)
						.opacity(configuration.isPressed ? Motion.pressOpacity : 1.0)
						.scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1.0)
				)
				.opacity(isEnabled ? 1.0 : 0.5)
				.animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
		}
	}
}

struct SecondaryButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		SecondaryButtonBody(configuration: configuration)
	}

	private struct SecondaryButtonBody: View {
		let configuration: ButtonStyleConfiguration
		@Environment(\.accessibilityReduceMotion) private var reduceMotion

		var body: some View {
			configuration.label
				.padding(.horizontal, 16)
				.font(.system(.body, design: .rounded))
				.foregroundColor(.primary)
				.frame(minHeight: ButtonMetrics.height)
				.background(
					RoundedRectangle(cornerRadius: ButtonMetrics.cornerRadius)
						.fill(Color.gray.opacity(0.2))
						// Secondary presses dim a touch further than Motion.pressOpacity
						// because the fill underneath is already low-contrast.
						.opacity(configuration.isPressed ? 0.7 : 1.0)
						.scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1.0)
				)
				.animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
		}
	}
}

// MARK: - Transcription Activity Window

// Single parameterized row for the Activity window. Replaces the popover's
// QueueStackCard/QueueListItem duplication: status badge, percent text (no
// progress ring), error text, and per-status actions (Copy / Reveal /
// Retry / split Cancel-Remove) reading the cached fileExists flag.
struct QueueRow: View, Equatable {
	@Bindable var item: TranscriptionQueueItem
	let queueManager: TranscriptionQueueManager
	@State private var didCopy = false
	@State private var copyResetTask: Task<Void, Never>?

	// Value-equality over the fields that drive this row's rendering. Paired with
	// .equatable() at the call site, completed/idle rows skip body re-evaluation
	// while the reference-type item still invalidates on genuine changes.
	static func == (lhs: QueueRow, rhs: QueueRow) -> Bool {
		lhs.item.id == rhs.item.id
			&& lhs.item.status == rhs.item.status
			&& lhs.item.progress == rhs.item.progress
			&& lhs.item.fileExists == rhs.item.fileExists
			&& lhs.item.displayName == rhs.item.displayName
			&& lhs.item.error == rhs.item.error
			&& (lhs.item.result?.isEmpty ?? true) == (rhs.item.result?.isEmpty ?? true)
	}

	private var isActive: Bool {
		item.status == QueueItemStatus.pending || item.status == QueueItemStatus.processing
	}

	var body: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle()
					.fill(item.status.color.opacity(0.2))
					.frame(width: 24, height: 24)

				Image(systemName: item.status.icon)
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(item.status.color)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(item.displayName)
					.font(.system(.body, design: .rounded, weight: .medium))
					.foregroundStyle(.primary)
					.lineLimit(1)
					.truncationMode(.middle)

				HStack(spacing: 4) {
					Text(item.status.displayName)
						.font(.caption)
						.foregroundStyle(.secondary)

					if item.status == QueueItemStatus.processing {
						Text("\(Int(item.progress * 100))%")
							.font(.caption)
							.monospacedDigit()
							.foregroundStyle(.secondary)
					}
				}

				if item.status == QueueItemStatus.failed, let error = item.error {
					Text(error)
						.font(.caption2)
						.foregroundStyle(.red)
						.lineLimit(2)
				}
			}

			Spacer()

			HStack(spacing: 10) {
				if item.status == QueueItemStatus.completed,
					let result = item.result, !result.isEmpty
				{
					Button(action: copyResult) {
						Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
							.font(.system(size: 14))
							.foregroundStyle(didCopy ? .green : .secondary)
					}
					.buttonStyle(.plain)
					.help(didCopy ? String(localized: "Copied") : String(localized: "Copy transcription"))
				}

				if item.status == QueueItemStatus.completed,
					item.fileExists,
					let filePath = item.filePath
				{
					Button {
						NSWorkspace.shared.selectFile(
							filePath,
							inFileViewerRootedAtPath: URL(fileURLWithPath: filePath)
								.deletingLastPathComponent().path)
					} label: {
						Image(systemName: "folder")
							.font(.system(size: 14))
							.foregroundStyle(.green)
					}
					.buttonStyle(.plain)
					.help("Reveal in Finder")
				}

				if item.status == QueueItemStatus.failed {
					Button {
						queueManager.retryItem(item)
					} label: {
						Image(systemName: "arrow.clockwise")
							.font(.system(size: 14))
							.foregroundStyle(.blue)
					}
					.buttonStyle(.plain)
					.help("Retry")
				}

				if isActive {
					Button {
						queueManager.cancelItem(item)
					} label: {
						Image(systemName: "stop.circle")
							.font(.system(size: 14))
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.help("Cancel")
				} else {
					Button {
						queueManager.removeItem(item)
					} label: {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 14))
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.help("Remove")
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
	}

	private func copyResult() {
		guard let result = item.result else { return }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(result, forType: .string)

		didCopy = true
		copyResetTask?.cancel()
		copyResetTask = Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			if !Task.isCancelled {
				didCopy = false
			}
		}
	}
}

struct ActivityView: View {
	@Bindable var queueManager: TranscriptionQueueManager
	@State private var showClearAllConfirm = false

	private var summary: String {
		QueueSummary.text(total: queueManager.items.count, processing: queueManager.processingItems.count)
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Transcription Activity")
					.font(.headline)

				Spacer()

				Text(summary)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 16)
			.padding(.top, 16)
			.padding(.bottom, 12)

			HStack(spacing: 8) {
				Button(role: .destructive) {
					showClearAllConfirm = true
				} label: {
					Label("Clear All", systemImage: "trash")
				}
				.disabled(queueManager.items.isEmpty)

				Button("Cancel All") {
					queueManager.cancelAll()
				}
				.disabled(!queueManager.isProcessing)

				Spacer()

				Button("Clear Completed") {
					queueManager.clearCompleted()
				}
				.disabled(queueManager.completedItems.isEmpty)

				Button("Retry Failed") {
					queueManager.retryFailed()
				}
				.disabled(queueManager.failedItems.isEmpty)
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 12)

			Divider()

			if queueManager.items.isEmpty {
				VStack(spacing: 8) {
					Image(systemName: "tray.and.arrow.down")
						.font(.system(size: 28))
						.foregroundStyle(.secondary)
					Text("Drop files or URLs here to transcribe")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollView {
					VStack(spacing: 8) {
						ForEach(queueManager.items, id: \.id) { item in
							QueueRow(item: item, queueManager: queueManager)
								.equatable()
						}
					}
					.padding(16)
				}
			}
		}
		.frame(minWidth: 480, minHeight: 320)
		.alert("Clear all transcriptions?", isPresented: $showClearAllConfirm) {
			Button("Clear All", role: .destructive) {
				queueManager.clearAll()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This removes every item, including completed and failed transcriptions.")
		}
	}
}

@MainActor
final class ActivityWindow: NSWindow {
	init(queueManager: TranscriptionQueueManager) {
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)

		self.title = String(localized: "Transcription Activity")
		self.titlebarAppearsTransparent = true
		self.isReleasedWhenClosed = false
		self.contentViewController = NSHostingController(
			rootView: ActivityView(queueManager: queueManager))
		self.setFrameAutosaveName("TranscriptionActivityWindow")
		self.center()
	}
}

// MARK: - Notification Banner

enum BannerType {
	case error
	case success

	var icon: String {
		switch self {
		case .error: return "exclamationmark.triangle.fill"
		case .success: return "checkmark.circle.fill"
		}
	}

	var color: Color {
		switch self {
		case .error: return .red
		case .success: return .green
		}
	}

	var backgroundColor: Color {
		switch self {
		case .error: return .red.opacity(0.1)
		case .success: return .green.opacity(0.1)
		}
	}
}

struct NotificationBanner: View {
	let message: String
	let type: BannerType
	var onDismiss: (() -> Void)? = nil

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: type.icon)
				.font(.system(size: 14))
				.foregroundColor(type.color)

			Text(message)
				.font(.caption)
				.foregroundColor(.primary)
				.lineLimit(5)
				.multilineTextAlignment(.leading)
				.fixedSize(horizontal: false, vertical: true)

			Spacer()

			if let onDismiss {
				Button(action: onDismiss) {
					Image(systemName: "xmark")
						.font(.system(size: 11, weight: .semibold))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help("Dismiss")
				.accessibilityLabel("Dismiss")
			}
		}
		.padding(12)
		.background {
			// The toast floats over the popover's buttons, so the 10% tint needs an opaque base
			// or the controls underneath read through the message
			RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Self.baseColor))
			RoundedRectangle(cornerRadius: 10).fill(type.backgroundColor)
		}
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(type.color.opacity(0.3), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
	}

	static let baseColor = NSColor.windowBackgroundColor
}

// MARK: - Toast center

// The single success/error language for the popover. Owns the current toast, its
// auto-dismiss timer, and the last message (retrievable from the "…" menu after it
// auto-dismisses). Anything that arrives while the popover is hidden also posts a
// system notification so the user does not miss it.
// Mutated only from the main actor (view event handlers and the AppDelegate menu
// handler); left un-annotated so its default initializer can seed an AppDelegate
// stored property.
@Observable
final class ToastCenter {
	struct Toast: Equatable {
		let id = UUID()
		let message: String
		let type: BannerType
	}

	private(set) var current: Toast?
	private(set) var lastMessage: Toast?

	// Reports whether the popover is on screen; injected by the AppDelegate. Only
	// missed-while-closed events get a system notification.
	@ObservationIgnored var isPopoverVisible: () -> Bool = { false }

	@ObservationIgnored private var dismissTask: Task<Void, Never>?
	@ObservationIgnored var deliverSystemNotification: (Toast) -> Void = ToastCenter.postSystemNotification

	private static let successDuration: TimeInterval = 3.0
	private static let errorDuration: TimeInterval = 8.0

	func show(_ message: String, type: BannerType, notifyWhenHidden: Bool = true) {
		let toast = Toast(message: message, type: type)
		current = toast
		lastMessage = toast

		if notifyWhenHidden, !isPopoverVisible() {
			deliverSystemNotification(toast)
		}

		let duration = type == .error ? ToastCenter.errorDuration : ToastCenter.successDuration
		dismissTask?.cancel()
		dismissTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self?.current = nil
		}
	}

	func dismiss() {
		dismissTask?.cancel()
		current = nil
	}

	// Reopens the most recent message; a cheap safety valve when a toast
	// auto-dismisses before it can be read.
	func showLastMessage() {
		guard let last = lastMessage else { return }
		show(last.message, type: last.type)
	}

	private static func postSystemNotification(_ toast: Toast) {
		let notification = NSUserNotification()
		notification.title = "Whispera"
		notification.subtitle = toast.type == .error ? String(localized: "Error") : ""
		notification.informativeText = toast.message
		NSUserNotificationCenter.default.deliver(notification)
	}
}

// The toast participates in the measured content height so it never covers controls.
// Success and error share one motion language.
struct ToastOverlay: View {
	let toastCenter: ToastCenter
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		VStack(spacing: 0) {
			if let toast = toastCenter.current {
				NotificationBanner(
					message: toast.message,
					type: toast.type,
					onDismiss: { toastCenter.dismiss() }
				)
				.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
			}
		}
		.padding(.bottom, 8)
		.padding(.horizontal, 8)
		.animation(reduceMotion ? nil : Motion.transient, value: toastCenter.current)
	}
}

// MARK: - Microphone Menu

// Native pull-down so opening the picker changes no popover height. The label
// shows the precomputed active device (no O(n) scan per render); the inline
// Picker draws a checkmark on the current selection. Picking a device mid-recording moves the
// capture onto it and keeps the audio already recorded.
struct MicMenu: View {
	@Bindable var audioManager: AudioManager
	@State private var deviceManager = AudioDeviceManager.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID

	private var activeName: String {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return String(localized: "System Default")
		}
		return deviceManager.activeDevice?.name ?? String(localized: "System Default")
	}

	private var activeIcon: String {
		deviceManager.activeDevice?.iconName ?? "mic.fill"
	}

	private var selectionBinding: Binding<String> {
		Binding(
			get: { selectedUID },
			set: { audioManager.switchInputDevice(to: $0) }
		)
	}

	var body: some View {
		Menu {
			Picker("Input Device", selection: selectionBinding) {
				Label("System Default", systemImage: "mic.fill")
					.tag(AudioDeviceManager.systemDefaultUID)

				ForEach(deviceManager.availableDevices) { device in
					Label(device.name, systemImage: device.iconName)
						.tag(device.uid)
				}
			}
			.pickerStyle(.inline)

			if deviceManager.availableDevices.isEmpty {
				Divider()
				Text("No input devices found")
			}
		} label: {
			HStack(spacing: 4) {
				Image(systemName: activeIcon)
					.font(.system(size: 12))
				Text(activeName)
					.font(.system(size: 12, design: .rounded))
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.foregroundStyle(.primary)
		}
		.menuStyle(.borderlessButton)
		// Borderless menus render as NSPopUpButton and size to intrinsic width;
		// without a hard cap a long device name pushes past the popover edge.
		.frame(maxWidth: 150, alignment: .trailing)
	}
}

// MARK: - Scoped composition subviews

// Slim, dismissible single-row update prompt. Sparkle owns the download and
// install flow; this row only surfaces availability and hands off to it.
struct UpdateRow: View {
	@ObservedObject var softwareUpdater: SoftwareUpdater
	let onDismiss: () -> Void

	var body: some View {
		if let latestVersion = softwareUpdater.availableUpdateVersion {
			HStack(spacing: 8) {
				Image(systemName: "arrow.up.circle.fill")
					.foregroundColor(.blue)

				Text("Update \(latestVersion) available")
					.font(.caption)
					.foregroundColor(.primary)
					.lineLimit(1)

				Spacer(minLength: 4)

				Button("Update") {
					softwareUpdater.checkForUpdates()
				}
				.buttonStyle(.bordered)
				.controlSize(.mini)
				.disabled(!softwareUpdater.canCheckForUpdates)

				Button(action: onDismiss) {
					Image(systemName: "xmark")
						.font(.system(size: 10, weight: .semibold))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help("Dismiss")
				.accessibilityLabel("Dismiss")
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(.blue.opacity(0.3), lineWidth: 1)
			)
		}
	}
}

struct HeaderLine: View {
	@Bindable var audioManager: AudioManager
	var whisperKit: WhisperKitTranscriber
	var permissionManager: PermissionManager
	@Bindable var fileTranscriptionManager: FileTranscriptionManager
	@Bindable var networkDownloader: NetworkFileDownloader
	let shortcutKey: String
	let menuEntries: [StatusMenuEntry]
	let performMenuAction: @MainActor (StatusMenuAction) -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var status: MenuBarStatusModel {
		MenuBarStatusModel(
			audioManager: audioManager,
			whisperKit: whisperKit,
			permissionManager: permissionManager,
			fileTranscriptionManager: fileTranscriptionManager,
			networkDownloader: networkDownloader,
			shortcutKey: shortcutKey
		)
	}

	var body: some View {
		let status = status
		HStack(spacing: 12) {
			HeaderGlyph(
				systemImage: status.systemImage,
				color: status.color,
				isRecording: audioManager.isRecording,
				reduceMotion: reduceMotion
			)
			.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(status.title)
						.font(.system(.headline, design: .rounded))
						.foregroundColor(.primary)

					if audioManager.isRecording {
						RecordingDurationLabel(audioManager: audioManager)
							.foregroundColor(.primary)
					}
				}

				Text(status.subtitle)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.accessibilityElement(children: .combine)

			Spacer()

			Button {
				performMenuAction(.settings)
			} label: {
				Image(systemName: "gearshape")
					.font(.system(size: 15))
					.foregroundColor(.secondary)
			}
			.buttonStyle(.plain)
			.help("Settings")
			.accessibilityLabel("Settings")

			Menu {
				ForEach(Array(menuEntries.enumerated()), id: \.offset) { _, entry in
					if let action = entry.action {
						Button(entry.title) { performMenuAction(action) }
							.disabled(!entry.isEnabled)
					} else {
						Divider()
					}
				}
			} label: {
				Image(systemName: "ellipsis")
					.font(.system(size: 15))
					.foregroundColor(.secondary)
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
			.help("More")
			.accessibilityLabel("More")
		}
	}
}

// Isolated glyph leaf: crossfades its SF Symbol on state change and pulses while
// recording, both gated on Reduce Motion.
struct HeaderGlyph: View {
	let systemImage: String
	let color: Color
	let isRecording: Bool
	let reduceMotion: Bool

	var body: some View {
		ZStack {
			Circle()
				.fill(color.opacity(0.2))
				.frame(width: 36, height: 36)

			// Same state-change treatment as the onboarding steps: the outgoing
			// glyph scales and fades out while the incoming one scales in.
			glyph
				.id(systemImage)
				.transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
		}
		.animation(reduceMotion ? nil : Motion.iconMorph, value: systemImage)
		.animation(reduceMotion ? nil : Motion.iconMorphTint, value: color)
		// Fence the glyph's local animations off from ancestor layout shifts:
		// when a Fix-It row collapses in the same beat as a state change, the
		// circle must jump with the layout, not slide in from its old position.
		.geometryGroup()
	}

	private var glyph: some View {
		Image(systemName: systemImage)
			.font(.system(size: 16, weight: .medium))
			.foregroundColor(color)
			.symbolEffect(.pulse, options: .repeating, isActive: isRecording && !reduceMotion)
	}
}

// MARK: - Dictate lane

// Record button, segmented mode control, native mic menu, and the shortcut
// reminder. Observes only AudioManager so record/mode changes never re-evaluate
// the header or the status card.
struct DictateLane: View {
	@Bindable var audioManager: AudioManager
	let shortcutKey: String
	let selectedLanguage: String
	let isBlocked: Bool

	@FocusState private var recordFocused: Bool

	var body: some View {
		VStack(spacing: 12) {
			RecordButton(audioManager: audioManager, isBlocked: isBlocked)
				.focused($recordFocused)

			// The cancel shortcut is not armed while transcribing, so this is the way out. It only
			// abandons transcriptions: a recording started meanwhile keeps running.
			if audioManager.isTranscribing {
				Button("Cancel Transcription") {
					audioManager.cancelTranscriptions()
				}
				.buttonStyle(TertiaryButtonStyle())
				.accessibilityIdentifier("menuBarCancelTranscriptionButton")
			}

			HStack(spacing: 12) {
				ModeControl(audioManager: audioManager, selectedLanguage: selectedLanguage)
					.layoutPriority(1)
				Spacer(minLength: 8)
				MicMenu(audioManager: audioManager)
			}

			// Text mode already shows the shortcut in the header subtitle.
			if audioManager.enableTranslation {
				ShortcutReminder(audioManager: audioManager, shortcutKey: shortcutKey)
			}
		}
		.defaultFocus($recordFocused, true)
		.onAppear { recordFocused = true }
	}
}

struct RecordButton: View {
	@Bindable var audioManager: AudioManager
	let isBlocked: Bool

	private var mode: RecordButtonMode {
		RecordButtonMode.resolve(
			capturing: audioManager.isSessionActive, transcribing: audioManager.isTranscribing)
	}

	var body: some View {
		let mode = mode
		Button {
			audioManager.toggleRecording()
		} label: {
			HStack(spacing: 8) {
				switch mode {
				case .transcribing:
					ProgressView()
						.controlSize(.small)
						.tint(.white)
					Text("Transcribing…")
						.font(.system(.body, design: .rounded, weight: .medium))
				case .stop:
					Image(systemName: "stop.fill")
					Text(String(localized: "Stop Recording"))
						.font(.system(.body, design: .rounded, weight: .medium))
				case .start:
					Image(systemName: "mic.fill")
					Text(String(localized: "Start Recording"))
						.font(.system(.body, design: .rounded, weight: .medium))
				}
			}
			.frame(maxWidth: .infinity)
			.frame(height: 40)
			.padding(.vertical, 10)
		}
		.buttonStyle(PrimaryButtonStyle(isRecording: mode == .stop))
		.disabled(!mode.isEnabled(blocked: isBlocked))
	}
}

// Segmented Text | Translate bound to the single enableTranslation source. Shows
// the source language code while translating so that datum is not lost.
struct ModeControl: View {
	@Bindable var audioManager: AudioManager
	let selectedLanguage: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Picker("Mode", selection: $audioManager.enableTranslation) {
				Text("Text").tag(false)
					.help("Transcribe speech as text")
				Text("Translate").tag(true)
					.help("Translate speech to English")
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()

			if audioManager.enableTranslation {
				Text(
						"\(Constants.isAutoDetectLanguage(selectedLanguage) ? "AUTO" : Constants.languageCode(for: selectedLanguage).uppercased()) → EN"
					)
					.font(.system(.caption2, design: .rounded, weight: .medium))
					.foregroundColor(.secondary)
			}
		}
	}
}

// Plain, honest caption sharing the single enableTranslation source with the
// mode control and header so the label can never desync.
struct ShortcutReminder: View {
	@Bindable var audioManager: AudioManager
	let shortcutKey: String

	var body: some View {
		HStack(spacing: 6) {
			Text(audioManager.enableTranslation ? String(localized: "Translate") : String(localized: "Text"))
			Text("·")
			Text(shortcutKey)
				.font(.system(.caption, design: .monospaced))
			Spacer()
		}
		.font(.caption)
		.foregroundColor(.secondary)
	}
}

// MARK: - Popover sizing

// Discrete, Equatable description of which popover modules are on screen. Height
// is derived from a per-module table rather than measured, so there is no
// measure -> set-frame -> remeasure feedback loop.
struct PopoverLayout: Equatable {
	var updateVisible: Bool
	var permissionRows: Int
	var modelPreparing: Bool
	var modelDownloading: Bool
	var hasResult: Bool
	var typeScale: CGFloat

	var needsPermissions: Bool { permissionRows > 0 }

	// Dynamic-Type scale factor applied to the whole module table so larger text
	// sizes grow the popover instead of clipping.
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

// Fixed popover width; height follows the measured content.
enum PopoverMetrics {
	static let width: CGFloat = 344
	static let minHeight: CGFloat = 160
}

// SwiftUI -> AppKit sizing bridge. The content reports its natural laid-out
// height; the AppDelegate assigns it to popover.contentSize explicitly because
// NSPopover animates explicit contentSize changes while shown - the passive
// preferredContentSize tracking path snaps in a single frame.
@Observable
final class PopoverPresenter {
	private(set) var height: CGFloat = 380
	/// True when the content is taller than the screen allows, so the popover scrolls.
	private(set) var scrolls = false

	func setMeasured(_ measured: CGFloat, visibleScreenHeight: CGFloat?) {
		let limit = PopoverHeightLimit(contentHeight: measured, visibleScreenHeight: visibleScreenHeight)
		if scrolls != limit.scrolls {
			scrolls = limit.scrolls
		}
		// Sub-point layout jitter must not re-trigger the AppKit resize.
		if abs(limit.height - height) > 1 {
			height = limit.height
		}
	}
}

// MARK: - Model switch notice

struct ModelSwitchNoticeRow: View {
	let notice: ModelSwitchNotice
	/// The download progress row already names the model while it downloads.
	let showsTitle: Bool

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			if showsTitle {
				ProgressView()
					.controlSize(.mini)
			} else {
				Image(systemName: "info.circle")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			VStack(alignment: .leading, spacing: 2) {
				if showsTitle {
					Text(notice.title(name: WhisperKitTranscriber.mediumModelName))
						.font(.caption)
						.fontWeight(.medium)
						.foregroundColor(.primary)
				}
				Text(notice.detail(name: WhisperKitTranscriber.mediumModelName))
					.font(.caption2)
					.foregroundColor(.secondary)
			}
			.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
		}
		.accessibilityElement(children: .combine)
		.accessibilityIdentifier("menuBarModelSwitchNotice")
	}
}
