import AppKit
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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	var statusItem: NSStatusItem?
	var popover = NSPopover()
	var audioManager: AudioManager!
	var shortcutManager: GlobalShortcutManager!
	var fileTranscriptionManager: FileTranscriptionManager!
	var networkDownloader: NetworkFileDownloader!
	var queueManager: TranscriptionQueueManager!
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
	private var liveTranscriptionWindow: LiveTranscriptionWindow?
	private var listeningWindow: ListeningWindow?
	private var iconAnimationTask: Task<Void, Never>?
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
			shortcutManager = GlobalShortcutManager()
			fileTranscriptionManager = FileTranscriptionManager()
			networkDownloader = NetworkFileDownloader()
			queueManager = TranscriptionQueueManager(
				fileTranscriptionManager: fileTranscriptionManager,
				networkDownloader: networkDownloader
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

	func setupMenuBar() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

		if let button = statusItem?.button {
			let image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
			image?.isTemplate = true
			button.image = image?.withSymbolConfiguration(statusIconConfig)
			button.action = #selector(togglePopover)
			button.target = self
		}

		popover.contentViewController = NSHostingController(
			rootView: MenuBarView(
				audioManager: audioManager,
				permissionManager: permissionManager ?? PermissionManager(),
				softwareUpdater: SoftwareUpdater.shared,
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
			return
		}

		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
		guard let button = statusItem?.button else { return }
		let whisperKit = audioManager.whisperKitTranscriber

		iconAnimationTask?.cancel()
		iconAnimationTask = nil
		button.alphaValue = 1.0

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
		iconAnimationTask = Task { @MainActor [weak self] in
			guard self != nil else { return }
			while !Task.isCancelled {
				await withCheckedContinuation { continuation in
					NSAnimationContext.runAnimationGroup { context in
						context.duration = duration
						context.allowsImplicitAnimation = true
						context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
						button.animator().alphaValue = fadeTo
					} completionHandler: {
						continuation.resume()
					}
				}
				if Task.isCancelled { break }
				await withCheckedContinuation { continuation in
					NSAnimationContext.runAnimationGroup { context in
						context.duration = duration
						context.allowsImplicitAnimation = true
						context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
						button.animator().alphaValue = 1.0
					} completionHandler: {
						continuation.resume()
					}
				}
			}
		}
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
