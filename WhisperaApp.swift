import AppKit
import Observation
import Sparkle
import SwiftUI

@main
struct WhisperaApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	private let softwareUpdater = SoftwareUpdater.shared

	var body: some Scene {
		Settings {
			SettingsWithMaterial(
				permissionManager: appDelegate.permissionManager ?? PermissionManager(),
				appLibraryManager: appDelegate.appLibraryManager ?? AppLibraryManager(),
				softwareUpdater: softwareUpdater
			)
		}
		.windowStyle(.hiddenTitleBar)
		.windowResizability(.automatic)
		.windowResizability(.automatic)
		.windowToolbarStyle(.unified(showsTitle: true))
		.defaultPosition(.center)
		.commands {
			CommandGroup(replacing: .appInfo) {
				Button("About Whispera") {
					NSApplication.shared.orderFrontStandardAboutPanel(
						options: [
							.applicationName: "Whispera",
							.applicationVersion: AppVersion.Constants.currentVersionString,
						]
					)
				}
			}
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView(updater: softwareUpdater.updater)
			}
		}

	}
}

struct SettingsWithMaterial: View {
	var permissionManager: PermissionManager
	var appLibraryManager: AppLibraryManager
	var softwareUpdater: SoftwareUpdater
	@AppStorage("materialStyle") private var materialStyleRaw = MaterialStyle.default.rawValue

	private var materialStyle: MaterialStyle {
		MaterialStyle(rawValue: materialStyleRaw)
	}

	var body: some View {
		if #available(macOS 15.0, *) {
			SettingsView(
				permissionManager: permissionManager,
				appLibraryManager: appLibraryManager,
				softwareUpdater: softwareUpdater
			)
			.frame(minWidth: 450, minHeight: 520)
			.containerBackground(materialStyle.material, for: .window)
		} else {
			SettingsView(
				permissionManager: permissionManager,
				appLibraryManager: appLibraryManager,
				softwareUpdater: softwareUpdater
			)
			.frame(minWidth: 450, minHeight: 520)
		}
	}
}

extension Notification.Name {
	/// Ask the app to open Settings. Surfaces that cannot reach the AppDelegate
	/// reliably (the pill's floating panels, where `NSApp.delegate` may be
	/// SwiftUI's adaptor wrapper rather than our class) post this instead of
	/// casting.
	static let openSettingsRequested = Notification.Name("OpenSettingsRequested")
}

enum SettingsDestination: String {
	case general, aiMode, recipes, storage, liveTranscription, fileTranscription, benchmark
}

enum SettingsRouting {
	static let destinationKey = "destination"
	static let selectedTabDefaultsKey = "whisperaSelectedSettingsTab"

	static func userInfo(destination: SettingsDestination) -> [String: Any] {
		[destinationKey: destination.rawValue]
	}

	static func destination(in userInfo: [AnyHashable: Any]?) -> SettingsDestination? {
		(userInfo?[destinationKey] as? String).flatMap(SettingsDestination.init(rawValue:))
	}
}

enum StatusMenuAction: String {
	case settings
	case activity
	case checkForUpdates
	case about
	case lastMessage
	case quit
}

struct StatusMenuEntry {
	let action: StatusMenuAction?
	let title: String
	let isEnabled: Bool

	static let separator = StatusMenuEntry(action: nil, title: "", isEnabled: false)
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	var statusItem: NSStatusItem?
	var popover = NSPopover()
	let toastCenter = ToastCenter()
	var audioManager: AudioManager!
	var shortcutManager: GlobalShortcutManager!
	var fileTranscriptionManager: FileTranscriptionManager!
	var networkDownloader: NetworkFileDownloader!
	var queueManager: TranscriptionQueueManager!
	var fileDropHandler: FileDropHandler!
	var permissionManager: PermissionManager?
	var appLibraryManager: AppLibraryManager?
	@AppStorage("globalShortcut") var globalShortcut = "⌥⌘R"
	@AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
	private var recordingObserver: NSObjectProtocol?
	private var downloadObserver: NSObjectProtocol?
	private var modelStateObserver: NSObjectProtocol?
	private var sleepObserver: NSObjectProtocol?
	private var wakeObserver: NSObjectProtocol?
	private var onboardingWindow: NSWindow?
	private var activityWindow: ActivityWindow?
	private var settingsWindow: NSWindow?
	private var swiftUIOpenSettings: (@MainActor () -> Void)?
	let popoverPresenter = PopoverPresenter()
	private var liveTranscriptionWindow: LiveTranscriptionWindow?
	private var listeningWindow: ListeningWindow?
	private static let alphaPulseKey = "whispera.statusItem.alphaPulse"
	private let statusIconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .medium)
	private var recordingGlowController: RecordingGlowController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		if shouldTerminateDuplicateInstances() {
			AppLogger.shared.general.info(
				"Another instance is already running. Activating existing instance and terminating this one."
			)
			activateExistingInstance()
			NSApp.terminate(nil)
			return
		}

		AppDelegate.registerInitialDefaults(in: .standard)

		Task { @MainActor in
			audioManager = AudioManager()
			let coordinator = DictationCoordinator.shared
			audioManager.dictationProcessor = { text in await coordinator.process(text) }
			shortcutManager = GlobalShortcutManager()
			fileTranscriptionManager = FileTranscriptionManager()
			networkDownloader = NetworkFileDownloader()
			queueManager = TranscriptionQueueManager(
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader
			)
			fileDropHandler = FileDropHandler(
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader,
				queueManager: queueManager
			)
			permissionManager = PermissionManager()
			appLibraryManager = AppLibraryManager()
			setupMenuBar()
			NSApp.setActivationPolicy(.accessory)
			shortcutManager.setAudioManager(audioManager)
			shortcutManager.setFileTranscriptionManager(fileTranscriptionManager)
			shortcutManager.setNetworkDownloader(networkDownloader)
			shortcutManager.setQueueManager(queueManager)
			observeRecordingState()
			observeWindowState()
			observeSleepWakeNotifications()

			liveTranscriptionWindow = LiveTranscriptionWindow(audioManager: audioManager)
			listeningWindow = ListeningWindow(audioManager: audioManager)
			recordingGlowController = RecordingGlowController(audioManager: audioManager)
			if !hasCompletedOnboarding {
				showOnboarding()
			}

			// Listen for show onboarding requests from settings
			NotificationCenter.default.addObserver(
				forName: NSNotification.Name("ShowOnboarding"),
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?.showOnboarding()
			}

			NotificationCenter.default.addObserver(
				forName: .openSettingsRequested,
				object: nil,
				queue: .main
			) { [weak self] notification in
				Task { @MainActor in
					if let destination = SettingsRouting.destination(in: notification.userInfo) {
						UserDefaults.standard.set(
							destination.rawValue, forKey: SettingsRouting.selectedTabDefaultsKey)
					}
					AppLogger.shared.general.info(
						"Settings open requested via notification, destination: \(SettingsRouting.destination(in: notification.userInfo)?.rawValue ?? "current")")
					self?.perform(.settings)
				}
			}

			// Listen for activation requests from other instances
			DistributedNotificationCenter.default().addObserver(
				forName: NSNotification.Name("ActivateApp"),
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?.activateApp()
			}
		}
	}

	nonisolated static func registerInitialDefaults(in defaults: UserDefaults) {
		defaults.register(defaults: [
			"selectedModel": "openai_whisper-small.en",
			"globalShortcut": "⌥⌘R",
			"startSound": "Tink",
			"stopSound": "Pop",
			"launchAtStartup": false,
			"soundFeedback": true,
			"enableRecordingGlow": true,
			"enableStreaming": Constants.enableStreamingDefault,
			"defaultTranscriptionMode": "timestamps",
			"showTimestamps": true,
			"timestampFormat": "MM:SS",
			"materialStyle": MaterialStyle.default.rawValue,
		])
	}

	@MainActor
	func setupMenuBar() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

		if let button = statusItem?.button {
			let image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
			image?.isTemplate = true
			button.image = image?.withSymbolConfiguration(statusIconConfig)
			button.action = #selector(handleStatusItemClick)
			button.target = self
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}

		let hostingController = NSHostingController(
			rootView: MenuBarView(
				audioManager: audioManager,
				permissionManager: permissionManager ?? PermissionManager(),
				softwareUpdater: SoftwareUpdater.shared,
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader,
				queueManager: queueManager,
				fileDropHandler: fileDropHandler,
				menuEntries: menuItems(),
				performMenuAction: { [weak self] action in self?.perform(action) },
				registerOpenSettings: { [weak self] action in self?.swiftUIOpenSettings = action },
				presenter: popoverPresenter,
				toastCenter: toastCenter
			))
		// Sizing is driven by explicit contentSize assignments (which NSPopover
		// animates while shown); hosting sizing options would snap-resize and
		// fight that animation.
		hostingController.sizingOptions = []
		popover.contentViewController = hostingController
		popover.contentSize = NSSize(width: PopoverMetrics.width, height: 380)
		toastCenter.isPopoverVisible = { [weak self] in self?.popover.isShown ?? false }
		popover.behavior = .semitransient

		// Arm the height observation BEFORE the pre-warm layout: the pre-warm
		// runs the first measurement, and a change landing before observation
		// starts would never reach the popover.
		observePopoverSize()

		if let hostingView = popover.contentViewController?.view {
			hostingView.wantsLayer = true
			hostingView.layer?.backgroundColor = NSColor.clear.cgColor
			// Pre-warm: force one layout at launch so the first click hits an
			// already-evaluated tree instead of building it on the click.
			hostingView.frame = NSRect(
				x: 0, y: 0, width: PopoverMetrics.width, height: 400)
			hostingView.layoutSubtreeIfNeeded()
		}

	}

	@objc func togglePopover() {
		guard let button = statusItem?.button else { return }

		if popover.isShown {
			popover.performClose(nil)
			return
		}

		// State often changes while the popover is closed with no layout running;
		// re-measure and size before showing so it never opens stale and clipped.
		if let hostingView = popover.contentViewController?.view {
			hostingView.layoutSubtreeIfNeeded()
		}
		MainActor.assumeIsolated { applyPopoverSize() }

		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
	}

	// Re-arms observation of the measured height. Applying while shown animates
	// the frame (NSPopover animates explicit contentSize changes); applying
	// while closed is instant, which is what the pre-show path wants.
	private func observePopoverSize() {
		withObservationTracking {
			_ = popoverPresenter.height
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.applyPopoverSize()
				self.observePopoverSize()
			}
		}
	}

	@MainActor
	private func applyPopoverSize() {
		let size = NSSize(width: PopoverMetrics.width, height: popoverPresenter.height)
		guard popover.contentSize != size else { return }
		popover.contentSize = size
	}

	@objc private func handleStatusItemClick() {
		let event = NSApp.currentEvent
		let isSecondaryClick =
			event?.type == .rightMouseUp
			|| (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

		if isSecondaryClick {
			showStatusMenu()
		} else {
			togglePopover()
		}
	}

	private func showStatusMenu() {
		guard let statusItem, let button = statusItem.button else { return }
		let menu = buildStatusMenu()
		// Attaching the menu makes the next click present it, matching the
		// standard NSStatusItem left-click-action / right-click-menu pattern.
		statusItem.menu = menu
		button.performClick(nil)
		statusItem.menu = nil
	}

	// Shared ordered list of status-item menu commands. The item list, not the
	// widget, is the single source of truth so a future in-popover "…" SwiftUI
	// Menu can be built from the same descriptors and stay in sync.
	private func menuItems() -> [StatusMenuEntry] {
		[
			StatusMenuEntry(action: .settings, title: "Settings…", isEnabled: true),
			StatusMenuEntry(action: .activity, title: "Transcription Activity…", isEnabled: true),
			StatusMenuEntry(action: .checkForUpdates, title: "Check for Updates…", isEnabled: true),
			StatusMenuEntry(action: .about, title: "About Whispera", isEnabled: true),
			.separator,
			StatusMenuEntry(action: .lastMessage, title: "Last Message", isEnabled: true),
			.separator,
			StatusMenuEntry(action: .quit, title: "Quit Whispera", isEnabled: true),
		]
	}

	private func buildStatusMenu() -> NSMenu {
		let menu = NSMenu()
		menu.autoenablesItems = false
		for entry in menuItems() {
			guard let action = entry.action else {
				menu.addItem(.separator())
				continue
			}
			let item = NSMenuItem(
				title: entry.title,
				action: #selector(handleMenuAction(_:)),
				keyEquivalent: ""
			)
			item.target = self
			item.isEnabled = entry.isEnabled
			item.representedObject = action.rawValue
			menu.addItem(item)
		}
		return menu
	}

	@MainActor
	@objc private func handleMenuAction(_ sender: NSMenuItem) {
		guard
			let rawValue = sender.representedObject as? String,
			let action = StatusMenuAction(rawValue: rawValue)
		else { return }
		perform(action)
	}

	// Single command handler shared by the status-item NSMenu and the header "…"
	// SwiftUI menu so both surfaces execute identical behavior.
	@MainActor
	func perform(_ action: StatusMenuAction) {
		switch action {
		case .settings:
			showSettingsWindow()
		case .activity:
			showActivityWindow()
		case .checkForUpdates:
			SoftwareUpdater.shared.checkForUpdates()
		case .about:
			showAboutPanel()
		case .lastMessage:
			toastCenter.showLastMessage()
		case .quit:
			NSApplication.shared.terminate(nil)
		}
	}

	// Settings open, two tiers. First try the native SwiftUI Settings scene via
	// the openSettings environment action registered by MenuBarView (the legacy
	// showSettingsWindow: selector was removed by Apple on macOS 14+). The action
	// silently no-ops when the environment lacks a scene bridge - a known gap for
	// accessory apps - so if no scene window materializes, fall back to a
	// retained window hosting the same settings view.
	//
	// A settings window that already exists is brought forward directly instead
	// of going through openSettings again: the environment action is not
	// reliable on repeat invocations, and re-running the 0.4s verification for a
	// window we can already see just adds a beat of dead time.
	@MainActor
	private func showSettingsWindow() {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)

		if let existing = settingsSceneWindow(requireVisible: false) ?? settingsWindow {
			AppLogger.shared.general.info("Settings window already exists, bringing it forward")
			existing.makeKeyAndOrderFront(nil)
			return
		}

		guard let action = swiftUIOpenSettings else {
			AppLogger.shared.general.info("openSettings not registered yet, using retained settings window")
			showRetainedSettingsWindow()
			return
		}

		action()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
			guard let self else { return }
			if let scene = self.settingsSceneWindow() {
				AppLogger.shared.general.info("Settings opened via native scene")
				scene.makeKeyAndOrderFront(nil)
			} else {
				AppLogger.shared.general.info("openSettings no-oped, using retained settings window")
				self.showRetainedSettingsWindow()
			}
		}
	}

	@MainActor
	private func settingsSceneWindow(requireVisible: Bool = true) -> NSWindow? {
		NSApp.windows.first {
			(!requireVisible || $0.isVisible)
				&& AppDelegate.isSettingsSceneIdentifier($0.identifier?.rawValue)
		}
	}

	nonisolated static func isSettingsSceneIdentifier(_ rawIdentifier: String?) -> Bool {
		rawIdentifier?.hasPrefix("com_apple_SwiftUI_Settings") == true
	}

	@MainActor
	private func showRetainedSettingsWindow() {
		if let window = settingsWindow {
			AppLogger.shared.general.info("Reusing retained settings window")
			window.makeKeyAndOrderFront(nil)
			return
		}
		AppLogger.shared.general.info("Creating retained settings window")
		let hosting = NSHostingController(
			rootView: SettingsWithMaterial(
				permissionManager: permissionManager ?? PermissionManager(),
				appLibraryManager: appLibraryManager ?? AppLibraryManager(),
				softwareUpdater: SoftwareUpdater.shared
			))
		let window = NSWindow(contentViewController: hosting)
		window.title = "Whispera Settings"
		window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
		window.isReleasedWhenClosed = false
		window.setContentSize(NSSize(width: 640, height: 560))
		window.center()
		settingsWindow = window
		window.makeKeyAndOrderFront(nil)
	}

	@MainActor
	private func showActivityWindow() {
		if activityWindow == nil {
			activityWindow = ActivityWindow(queueManager: queueManager)
		}
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		activityWindow?.makeKeyAndOrderFront(nil)
	}

	private func showAboutPanel() {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		NSApplication.shared.orderFrontStandardAboutPanel(options: [
			.applicationName: "Whispera",
			.applicationVersion: AppVersion.Constants.currentVersionString,
		])
	}
	private func showOnboarding() {
		let onboardingView = OnboardingView(
			audioManager: audioManager,
			shortcutManager: shortcutManager
		)

		let hostingController = NSHostingController(rootView: onboardingView)

		onboardingWindow = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 600, height: 750),
			styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)

		onboardingWindow?.title = "Welcome to Whispera"
		onboardingWindow?.titlebarAppearsTransparent = true
		onboardingWindow?.isOpaque = false
		onboardingWindow?.backgroundColor = .clear
		onboardingWindow?.contentViewController = hostingController
		onboardingWindow?.center()
		onboardingWindow?.makeKeyAndOrderFront(nil)

		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		NotificationCenter.default.addObserver(
			forName: NSNotification.Name("OnboardingCompleted"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			NSApp.setActivationPolicy(.accessory)
			self?.onboardingWindow?.close()
			Task { @MainActor in
				self?.applyStoredModel()
			}
		}
	}

	private func observeRecordingState() {
		recordingObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
				self?.recordingGlowController?.updateVisibility()
			}
		}

		// Also observe download state changes
		downloadObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("DownloadStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
			}
		}

		// Observe model state changes for menu bar updates
		modelStateObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("WhisperKitModelStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
			}
		}

		// Observe file transcription notifications
		NotificationCenter.default.addObserver(
			forName: .fileTranscriptionSuccess,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
			}
		}

		NotificationCenter.default.addObserver(
			forName: .fileTranscriptionError,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
			}
		}

		// Observe queue processing state changes
		NotificationCenter.default.addObserver(
			forName: NSNotification.Name("QueueProcessingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateStatusIcon()
			}
		}
	}

	private func observeWindowState() {
		// Monitor when settings/preferences windows close to revert to accessory mode
		NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification,
			object: nil,
			queue: .main
		) { notification in
			if let window = notification.object as? NSWindow {
				let title = window.title.lowercased()
				if title.contains("settings") || title.contains("preferences")
					|| title.contains("activity")
				{
					// Settings or Activity window is closing, revert to accessory mode
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						NSApp.setActivationPolicy(.accessory)
					}
				}
			}
		}
	}

	@MainActor
	private func updateStatusIcon() {
		guard let button = statusItem?.button else { return }
		let whisperKit = audioManager.whisperKitTranscriber

		stopAlphaPulse(on: button)

		if permissionManager?.needsPermissions == true {
			setStatusImage("exclamationmark.triangle.fill", description: "Permissions Required", on: button)
			startAlphaPulse(on: button, fadeTo: 0.5, duration: 0.6)

		} else if whisperKit.isDownloadingModel || networkDownloader?.isDownloading == true {
			setStatusImage("arrow.down.circle", description: "Downloading", on: button)
			startAlphaPulse(on: button, fadeTo: 0.3, duration: 0.8)

		} else if audioManager.isTranscribing || fileTranscriptionManager?.isTranscribing == true
			|| queueManager?.isProcessing == true
		{
			setStatusImage("waveform", description: "Transcribing", on: button)
			startAlphaPulse(on: button, fadeTo: 0.7, duration: 1.5)

		} else if audioManager.isRecording {
			setStatusImage("mic.circle.fill", description: "Recording", on: button)
			startAlphaPulse(on: button, fadeTo: 0.4, duration: 0.8)

		} else {
			setStatusImage("microphone", description: "Ready", on: button)
		}
	}

	private func setStatusImage(_ symbolName: String, description: String, on button: NSStatusBarButton) {
		let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Whispera - \(description)")
		image?.isTemplate = true
		button.image = image?.withSymbolConfiguration(statusIconConfig)
	}

	private func startAlphaPulse(on button: NSStatusBarButton, fadeTo: CGFloat, duration: CGFloat) {
		// Render-server layer animation instead of a per-frame main-actor loop; gate on Reduce Motion.
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
		button.wantsLayer = true
		guard let layer = button.layer else { return }
		let animation = CABasicAnimation(keyPath: "opacity")
		animation.fromValue = 1.0
		animation.toValue = fadeTo
		animation.duration = CFTimeInterval(duration)
		animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		animation.autoreverses = true
		animation.repeatCount = .infinity
		layer.add(animation, forKey: Self.alphaPulseKey)
	}

	private func stopAlphaPulse(on button: NSStatusBarButton) {
		button.layer?.removeAnimation(forKey: Self.alphaPulseKey)
		button.alphaValue = 1.0
	}

	@MainActor private func applyStoredModel() {
		let storedModel =
			UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"

		guard audioManager.whisperKitTranscriber.isInitialized else {
			AppLogger.shared.general.info("WhisperKit not initialized, cannot switch model")
			return
		}

		guard storedModel != audioManager.whisperKitTranscriber.currentModel else {
			AppLogger.shared.general.info("Model already matches stored preference: \(storedModel)")
			return
		}

		AppLogger.shared.general.info("Applying stored model after onboarding: \(storedModel)")
		Task {
			do {
				try await audioManager.whisperKitTranscriber.switchModel(to: storedModel)
				AppLogger.shared.general.info("Successfully switched to stored model: \(storedModel)")
			} catch {
				AppLogger.shared.general.error("Failed to switch to stored model: \(error)")
			}
		}
	}

	private func observeSleepWakeNotifications() {
		sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.willSleepNotification,
			object: nil,
			queue: .main
		) { _ in
			AppLogger.shared.general.info("System will sleep")
		}

		wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didWakeNotification,
			object: nil,
			queue: .main
		) { _ in
			AppLogger.shared.general.info("System did wake")
		}
	}

	private func activateApp() {
		NSApp.activate(ignoringOtherApps: true)
		if let button = statusItem?.button {
			if !popover.isShown {
				popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			}
		}
	}

	// MARK: - Single Instance Management
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if let button = statusItem?.button {
			if !popover.isShown {
				popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			}
		}
		return true
	}

	private func shouldTerminateDuplicateInstances() -> Bool {
		let existingInstances = checkForExistingInstances()
		return !existingInstances.isEmpty
	}

	func checkForExistingInstances() -> [NSRunningApplication] {
		guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
			return []
		}
		let runningApps = NSWorkspace.shared.runningApplications
		return runningApps.filter { app in
			app.bundleIdentifier == bundleIdentifier && app != NSRunningApplication.current
		}
	}

	private func activateExistingInstance() {
		let existingInstances = checkForExistingInstances()
		if let existingInstance = existingInstances.first {
			existingInstance.activate(options: .activateAllWindows)
			let notification = Notification(name: NSNotification.Name("ActivateApp"))
			DistributedNotificationCenter.default().post(notification)
		}
	}

	@discardableResult
	func terminateDuplicateInstances() -> Bool {
		let existingInstances = checkForExistingInstances()

		for instance in existingInstances {
			instance.terminate()
		}

		return true
	}

	deinit {
		if let observer = recordingObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = downloadObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = modelStateObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = sleepObserver {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
		if let observer = wakeObserver {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
	}
}
