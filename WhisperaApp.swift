import AppKit
import SwiftUI

@main
struct WhisperaApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	var body: some Scene {
		Settings {
			SettingsWithMaterial(
				permissionManager: appDelegate.permissionManager ?? PermissionManager(),
				updateManager: appDelegate.updateManager ?? UpdateManager(),
				appLibraryManager: appDelegate.appLibraryManager ?? AppLibraryManager(),
				audioManager: appDelegate.audioManager ?? AudioManager()
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
		}

	}
}

struct SettingsWithMaterial: View {
	var permissionManager: PermissionManager
	var updateManager: UpdateManager
	var appLibraryManager: AppLibraryManager
	var audioManager: AudioManager
	@AppStorage("materialStyle") private var materialStyleRaw = MaterialStyle.default.rawValue

	private var materialStyle: MaterialStyle {
		MaterialStyle(rawValue: materialStyleRaw)
	}

	var body: some View {
		if #available(macOS 15.0, *) {
			SettingsView(
				permissionManager: permissionManager,
				updateManager: updateManager,
				appLibraryManager: appLibraryManager,
				audioManager: audioManager
			)
			.frame(minWidth: 450, minHeight: 520)
			.containerBackground(materialStyle.material, for: .window)
		} else {
			SettingsView(
				permissionManager: permissionManager,
				updateManager: updateManager,
				appLibraryManager: appLibraryManager,
				audioManager: audioManager
			)
			.frame(minWidth: 450, minHeight: 520)
		}
	}
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	var statusItem: NSStatusItem?
	var popover = NSPopover()
	var audioManager: AudioManager!
	var shortcutManager: GlobalShortcutManager!
	var fileTranscriptionManager: FileTranscriptionManager!
	var networkDownloader: NetworkFileDownloader!
	var queueManager: TranscriptionQueueManager!
	var updateManager: UpdateManager?
	var permissionManager: PermissionManager?
	var appLibraryManager: AppLibraryManager?
	@AppStorage("globalShortcut") var globalShortcut = "⌥⌘R"
	@AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
	@AppStorage("showMenuBarIcon") var showMenuBarIcon = true
	private var recordingObserver: NSObjectProtocol?
	private var downloadObserver: NSObjectProtocol?
	private var modelStateObserver: NSObjectProtocol?
	private var updateObserver: NSObjectProtocol?
	private var sleepObserver: NSObjectProtocol?
	private var wakeObserver: NSObjectProtocol?
	private var onboardingWindow: NSWindow?
	private var liveTranscriptionWindow: LiveTranscriptionWindow?
	private var listeningWindow: ListeningWindow?
	private var popoverFrame: NSRect?
	private var menuBarIconObserver: NSObjectProtocol?
	private var settingsSceneRepresentation: AnyObject?

	func applicationDidFinishLaunching(_ notification: Notification) {
		if shouldTerminateDuplicateInstances() {
			AppLogger.shared.general.info(
				"🚫 Another instance is already running. Activating existing instance and terminating this one."
			)
			activateExistingInstance()
			NSApp.terminate(nil)
			return
		}

		setupDefaultsIfNeeded()

		Task { @MainActor in
			audioManager = AudioManager()
			shortcutManager = GlobalShortcutManager()
			fileTranscriptionManager = FileTranscriptionManager()
			networkDownloader = NetworkFileDownloader()
			queueManager = TranscriptionQueueManager(
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader
			)
			updateManager = UpdateManager()
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
			observeUpdateState()
			observeSleepWakeNotifications()

			liveTranscriptionWindow = LiveTranscriptionWindow(audioManager: audioManager)
			listeningWindow = ListeningWindow(audioManager: audioManager)
			observeMenuBarIconSetting()
			if !hasCompletedOnboarding {
				showOnboarding()
			}

			if updateManager?.autoCheckForUpdates == true {
				Task {
					do {
						let hasUpdate = try await updateManager?.checkForUpdates() ?? false
						if hasUpdate {
							AppLogger.shared.general.info(
								"🆕 Update available: \(self.updateManager?.latestVersion ?? "unknown")")
						} else {
							AppLogger.shared.general.info("✅ App is up to date")
						}
					} catch {
						AppLogger.shared.general.info("⚠️ Failed to check for updates: \(error)")
					}
				}
			}

			// Listen for show onboarding requests from settings
			NotificationCenter.default.addObserver(
				forName: NSNotification.Name("ShowOnboarding"),
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?.showOnboarding()
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

	private func setupDefaultsIfNeeded() {
		// Set default values if they don't exist
		if UserDefaults.standard.object(forKey: "selectedModel") == nil {
			UserDefaults.standard.set("openai_whisper-small.en", forKey: "selectedModel")
		}

		if UserDefaults.standard.object(forKey: "globalShortcut") == nil {
			UserDefaults.standard.set("⌥⌘R", forKey: "globalShortcut")
		}

		if UserDefaults.standard.object(forKey: "startSound") == nil {
			UserDefaults.standard.set("Tink", forKey: "startSound")
		}

		if UserDefaults.standard.object(forKey: "stopSound") == nil {
			UserDefaults.standard.set("Pop", forKey: "stopSound")
		}

		if UserDefaults.standard.object(forKey: "launchAtStartup") == nil {
			UserDefaults.standard.set(false, forKey: "launchAtStartup")
		}

		if UserDefaults.standard.object(forKey: "soundFeedback") == nil {
			UserDefaults.standard.set(true, forKey: "soundFeedback")
		}

		if UserDefaults.standard.object(forKey: "materialStyle") == nil {
			UserDefaults.standard.set(MaterialStyle.default.rawValue, forKey: "materialStyle")
		}

		AppLogger.shared.general.info(
			"🔧 Setup defaults - Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "none")"
		)
	}

	func setupMenuBar() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

		if let button = statusItem?.button {
			button.image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
			button.action = #selector(togglePopover)
			button.target = self
		}

		popover.contentViewController = NSHostingController(
			rootView: MenuBarView(
				audioManager: audioManager,
				permissionManager: permissionManager ?? PermissionManager(),
				updateManager: updateManager ?? UpdateManager(),
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader,
				queueManager: queueManager
			))
		popover.behavior = .semitransient

		if let hostingView = popover.contentViewController?.view {
			hostingView.wantsLayer = true
			hostingView.layer?.backgroundColor = NSColor.clear.cgColor
		}

		if #available(macOS 14.0, *) {
			popover.hasFullSizeContent = true
		}
	}

	@objc func togglePopover() {
		guard let button = statusItem?.button else { return }

		if popover.isShown {
			popover.performClose(nil)
			popoverFrame = nil
			return
		}

		guard let screen = button.window?.screen,
			let buttonWindow = button.window,
			let hostingView = popover.contentViewController?.view
		else {
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			return
		}

		let screenFrame = screen.visibleFrame
		let buttonFrame = buttonWindow.frame
		let popoverSize = hostingView.fittingSize
		let margin: CGFloat = 8

		let spaceRight = screenFrame.maxX - buttonFrame.maxX
		let spaceLeft = buttonFrame.minX - screenFrame.minX

		let wouldOverflowRight = spaceRight < popoverSize.width
		let wouldOverflowLeft = spaceLeft < popoverSize.width

		if wouldOverflowRight || wouldOverflowLeft {
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

			DispatchQueue.main.async {
				guard let popoverWindow = self.popover.contentViewController?.view.window else { return }
				var popoverFrame = popoverWindow.frame

				if wouldOverflowRight {
					popoverFrame.origin.x = screenFrame.maxX - popoverSize.width - margin
				} else if wouldOverflowLeft {
					popoverFrame.origin.x = screenFrame.minX + margin
				}

				popoverWindow.setFrame(popoverFrame, display: true, animate: false)
				self.popoverFrame = popoverFrame
			}
		} else {
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			DispatchQueue.main.async {
				if let popoverWindow = self.popover.contentViewController?.view.window {
					self.popoverFrame = popoverWindow.frame
				}
			}
		}
	}

	private func restorePopoverPositionIfNeeded() {
		guard popover.isShown,
			let savedFrame = popoverFrame,
			let popoverWindow = popover.contentViewController?.view.window
		else {
			return
		}

		if popoverWindow.frame != savedFrame {
			popoverWindow.setFrame(savedFrame, display: false, animate: false)
		}
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
				if title.contains("settings") || title.contains("preferences") {
					// Settings window is closing, revert to accessory mode
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						NSApp.setActivationPolicy(.accessory)
					}
				}
			}
		}
	}

	@MainActor
	private func updateStatusIcon() {
		if let button = statusItem?.button {
			let whisperKit = audioManager.whisperKitTranscriber

			// Clean up any previous subviews and stop any animations
			button.subviews.removeAll()
			button.layer?.removeAllAnimations()

			let wasPopoverShown = popover.isShown

			if permissionManager?.needsPermissions == true {
				// Permission warning state - orange exclamation mark with pulse
				button.image = NSImage(
					systemSymbolName: "exclamationmark.triangle.fill",
					accessibilityDescription: "Whispera - Permissions Required")
				button.image?.isTemplate = true
				button.alphaValue = 1.0

				// Add warning pulse animation
				addPermissionWarningAnimation(to: button)

			} else if whisperKit.isDownloadingModel {
				// Downloading state - rotating download icon to indicate progress
				button.image = NSImage(
					systemSymbolName: "arrow.down.circle", accessibilityDescription: "Whispera - Downloading")
				button.image?.isTemplate = true
				button.alphaValue = 1.0

				// Add continuous rotation animation to indicate download
				addDownloadAnimation(to: button)

			} else if networkDownloader?.isDownloading == true {
				// Network downloading state - arrow down with rotation
				button.image = NSImage(
					systemSymbolName: "arrow.down.circle", accessibilityDescription: "Whispera - Downloading")
				button.image?.isTemplate = true
				button.alphaValue = 1.0

				// Add download animation
				addDownloadAnimation(to: button)

			} else if audioManager.isTranscribing || fileTranscriptionManager?.isTranscribing == true
				|| queueManager?.isProcessing == true
			{
				// Transcribing state - waveform icon with subtle pulse
				button.image = NSImage(
					systemSymbolName: "waveform", accessibilityDescription: "Whispera - Transcribing")
				button.image?.isTemplate = true
				button.alphaValue = 1.0

				// Add gentle pulsing for transcription
				addTranscriptionAnimation(to: button)

			} else if audioManager.isRecording {
				// Recording state - filled microphone icon with stronger pulse
				button.image = NSImage(
					systemSymbolName: "mic.circle.fill", accessibilityDescription: "Whispera - Recording")
				button.image?.isTemplate = true

				// Add a stronger pulsing animation to show active recording
				addRecordingAnimation(to: button)
			} else {
				// Ready state - default microphone icon, no animation
				button.image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
				button.image?.isTemplate = true
				button.alphaValue = 1.0
			}

			if wasPopoverShown {
				DispatchQueue.main.async {
					self.restorePopoverPositionIfNeeded()
				}
			}
		}
	}

	private func addDownloadAnimation(to button: NSStatusBarButton) {
		// Use NSAnimationContext instead of Core Animation for status bar buttons
		button.alphaValue = 1.0
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.8
			context.allowsImplicitAnimation = true
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			button.animator().alphaValue = 0.3
		} completionHandler: {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.8
				context.allowsImplicitAnimation = true
				context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
				button.animator().alphaValue = 1.0
			} completionHandler: {
				// Continue animation if still downloading
				Task { @MainActor in
					if self.audioManager.whisperKitTranscriber.isDownloadingModel
						|| self.networkDownloader?.isDownloading == true
					{
						self.addDownloadAnimation(to: button)
					}
				}
			}
		}
	}

	private func addPermissionWarningAnimation(to button: NSStatusBarButton) {
		// Warning pulse for permissions - faster and more urgent than other animations
		button.alphaValue = 1.0
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.6
			context.allowsImplicitAnimation = true
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			button.animator().alphaValue = 0.5
		} completionHandler: {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.6
				context.allowsImplicitAnimation = true
				context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
				button.animator().alphaValue = 1.0
			} completionHandler: {
				// Continue animation if still needs permissions
				if self.permissionManager?.needsPermissions == true {
					self.addPermissionWarningAnimation(to: button)
				}
			}
		}
	}

	private func addTranscriptionAnimation(to button: NSStatusBarButton) {
		// Gentle pulsing for transcription
		button.alphaValue = 1.0
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 1.5
			context.allowsImplicitAnimation = true
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			button.animator().alphaValue = 0.7
		} completionHandler: {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 1.5
				context.allowsImplicitAnimation = true
				context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
				button.animator().alphaValue = 1.0
			} completionHandler: {
				Task { @MainActor in
					if self.audioManager.isTranscribing {
						self.addTranscriptionAnimation(to: button)
					}
				}
			}
		}
	}

	private func addRecordingAnimation(to button: NSStatusBarButton) {
		// Stronger pulsing for recording
		button.alphaValue = 1.0
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.8
			context.allowsImplicitAnimation = true
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			button.animator().alphaValue = 0.4
		} completionHandler: {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.8
				context.allowsImplicitAnimation = true
				context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
				button.animator().alphaValue = 1.0
			} completionHandler: {
				Task { @MainActor in
					if self.audioManager.isRecording {
						self.addRecordingAnimation(to: button)
					}
				}
			}
		}
	}

	@MainActor private func applyStoredModel() {
		let storedModel =
			UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"

		guard audioManager.whisperKitTranscriber.isInitialized else {
			AppLogger.shared.general.info("⚠️ WhisperKit not initialized, cannot switch model")
			return
		}

		guard storedModel != audioManager.whisperKitTranscriber.currentModel else {
			AppLogger.shared.general.info("📝 Model already matches stored preference: \(storedModel)")
			return
		}

		AppLogger.shared.general.info("🔄 Applying stored model after onboarding: \(storedModel)")
		Task {
			do {
				try await audioManager.whisperKitTranscriber.switchModel(to: storedModel)
				AppLogger.shared.general.info("✅ Successfully switched to stored model: \(storedModel)")
			} catch {
				AppLogger.shared.general.info("❌ Failed to switch to stored model: \(error)")
			}
		}
	}

	private func observeUpdateState() {
		// Observe update availability notifications
		updateObserver = NotificationCenter.default.addObserver(
			forName: UpdateManager.updateAvailableNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			if let version = notification.userInfo?["version"] as? String {
				self?.showUpdateAvailableNotification(version: version)
			}
		}
	}

	private func observeSleepWakeNotifications() {
		sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.willSleepNotification,
			object: nil,
			queue: .main
		) { _ in
			AppLogger.shared.general.info("💤 System will sleep")
		}

		wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didWakeNotification,
			object: nil,
			queue: .main
		) { _ in
			AppLogger.shared.general.info("☀️ System did wake")
		}
	}

	private func observeMenuBarIconSetting() {
		updateMenuBarVisibility()

		menuBarIconObserver = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateMenuBarVisibility()
			}
		}
	}

	private func updateMenuBarVisibility() {
		if showMenuBarIcon {
			if statusItem == nil {
				setupMenuBar()
			}
		} else {
			if let item = statusItem {
				NSStatusBar.system.removeStatusItem(item)
				statusItem = nil
			}
		}
	}

	private func showUpdateAvailableNotification(version: String) {
		let alert = NSAlert()
		alert.messageText = "Update Available"
		alert.informativeText = "Whispera \(version) is available. Would you like to download it now?"
		alert.addButton(withTitle: "Download")
		alert.addButton(withTitle: "Later")
		alert.addButton(withTitle: "View Release Notes")

		let response = alert.runModal()
		switch response {
		case .alertFirstButtonReturn:
			// Download update
			Task {
				do {
					try await updateManager?.downloadUpdate()
				} catch {
					AppLogger.shared.general.info("❌ Failed to download update: \(error)")
				}
			}
		case .alertThirdButtonReturn:
			// Open GitHub releases page
			if let url = URL(string: "https://github.com/\(AppVersion.Constants.githubRepo)/releases") {
				NSWorkspace.shared.open(url)
			}
		default:
			break
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
		if showMenuBarIcon, let button = statusItem?.button {
			if !popover.isShown {
				popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			}
		} else {
			openSettingsWindow()
		}
		return true
	}

	private func openSettingsWindow() {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)

		if #available(macOS 26.0, *) {
			Task { @MainActor in
				if self.settingsSceneRepresentation == nil {
					let scene = NSHostingSceneRepresentation {
						Settings {
							SettingsWithMaterial(
								permissionManager: self.permissionManager ?? PermissionManager(),
								updateManager: self.updateManager ?? UpdateManager(),
								appLibraryManager: self.appLibraryManager ?? AppLibraryManager(),
								audioManager: self.audioManager ?? AudioManager()
							)
						}
					}
					NSApplication.shared.addSceneRepresentation(scene)
					self.settingsSceneRepresentation = scene
				}
				if let scene = self.settingsSceneRepresentation as? NSHostingSceneRepresentation<Settings<SettingsWithMaterial>> {
					scene.environment.openSettings()
				}
			}
		} else if #available(macOS 14.0, *) {
			NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
		} else if #available(macOS 13.0, *) {
			NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
		} else {
			NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
		}
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
		if let observer = updateObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = sleepObserver {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
		if let observer = wakeObserver {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
		if let observer = menuBarIconObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}
}
