import SwiftUI
import AppKit

@main
struct WhisperaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
			SettingsView(
                permissionManager: appDelegate.permissionManager ?? PermissionManager(),
                updateManager: appDelegate.updateManager ?? UpdateManager(),
                appLibraryManager: appDelegate.appLibraryManager ?? AppLibraryManager()
            )
        }
		.windowResizability(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
		.defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Whispera") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Whispera",
                            .applicationVersion: AppVersion.Constants.currentVersionString
                        ]
                    )
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var audioManager: AudioManager!
    var shortcutManager: GlobalShortcutManager!
    var updateManager: UpdateManager?
    var permissionManager: PermissionManager?
    var appLibraryManager: AppLibraryManager?
    @AppStorage("globalShortcut") var globalShortcut = "⌥⌘R"
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    private var recordingObserver: NSObjectProtocol?
    private var downloadObserver: NSObjectProtocol?
    private var modelStateObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var onboardingWindow: NSWindow?
    private var liveTranscriptionWindow: LiveTranscriptionWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for existing instances first
        if shouldTerminateDuplicateInstances() {
            print("🚫 Another instance is already running. Activating existing instance and terminating this one.")
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        
        setupDefaultsIfNeeded()
        
        Task { @MainActor in
            audioManager = AudioManager()
            shortcutManager = GlobalShortcutManager()
            updateManager = UpdateManager()
            permissionManager = PermissionManager()
            appLibraryManager = AppLibraryManager()
            setupMenuBar()
            NSApp.setActivationPolicy(.accessory)
            shortcutManager.setAudioManager(audioManager)
            observeRecordingState()
            observeWindowState()
            observeUpdateState()
            
            liveTranscriptionWindow = LiveTranscriptionWindow()
            liveTranscriptionWindow = LiveTranscriptionWindow()
            if !hasCompletedOnboarding {
                showOnboarding()
            }
          
            if updateManager?.autoCheckForUpdates == true {
                Task {
                    do {
                        let hasUpdate = try await updateManager?.checkForUpdates() ?? false
                        if hasUpdate {
                            print("🆕 Update available: \(updateManager?.latestVersion ?? "unknown")")
                        } else {
                            print("✅ App is up to date")
                        }
                    } catch {
                        print("⚠️ Failed to check for updates: \(error)")
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
        
        print("🔧 Setup defaults - Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "none")")
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            audioManager: audioManager,
            permissionManager: permissionManager ?? PermissionManager(),
            updateManager: updateManager ?? UpdateManager()
        ))
        popover.behavior = .transient
    }
    
    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
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
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        onboardingWindow?.title = "Welcome to Whispera"
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
    }
    
    private func observeWindowState() {
        // Monitor when settings/preferences windows close to revert to accessory mode
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
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
            
            if permissionManager?.needsPermissions == true {
                // Permission warning state - orange exclamation mark with pulse
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Whispera - Permissions Required")
                button.image?.isTemplate = true
                button.alphaValue = 1.0
                
                // Add warning pulse animation
                addPermissionWarningAnimation(to: button)
                
            } else if whisperKit.isDownloadingModel {
                // Downloading state - rotating download icon to indicate progress
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Whispera - Downloading")
                button.image?.isTemplate = true
                button.alphaValue = 1.0
                
                // Add continuous rotation animation to indicate download
                addDownloadAnimation(to: button)
                
            } else if audioManager.isTranscribing {
                // Transcribing state - waveform icon with subtle pulse
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whispera - Transcribing")
                button.image?.isTemplate = true
                button.alphaValue = 1.0
                
                // Add gentle pulsing for transcription
                addTranscriptionAnimation(to: button)
                
            } else if audioManager.isRecording {
                // Recording state - filled microphone icon with stronger pulse
                button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Whispera - Recording")
                button.image?.isTemplate = true
                
                // Add a stronger pulsing animation to show active recording
                addRecordingAnimation(to: button)
            } else {
                // Ready state - default microphone icon, no animation
                button.image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
                button.image?.isTemplate = true
                button.alphaValue = 1.0
            }
        }
    }
    
	private func addDownloadAnimation(to button: NSStatusBarButton) {
		button.wantsLayer = true
		
		guard let layer = button.layer else { return }
		
		// Continuous alpha animation (fade in/out)
		let alphaAnimation = CABasicAnimation(keyPath: "opacity")
		alphaAnimation.fromValue = 1.0
		alphaAnimation.toValue = 0.3  // Fade to 30% opacity
		alphaAnimation.duration = 0.8
		alphaAnimation.repeatCount = .infinity
		alphaAnimation.autoreverses = true  // This makes it fade back in
		alphaAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		
		layer.add(alphaAnimation, forKey: "downloadAlpha")
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
                // Continue animation if still transcribing
                if self.audioManager.isTranscribing {
                    self.addTranscriptionAnimation(to: button)
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
                // Continue animation if still recording
                if self.audioManager.isRecording {
                    self.addRecordingAnimation(to: button)
                }
            }
        }
    }
    
    @MainActor private func applyStoredModel() {
        let storedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"
        
        guard audioManager.whisperKitTranscriber.isInitialized else {
            print("⚠️ WhisperKit not initialized, cannot switch model")
            return
        }
        
        guard storedModel != audioManager.whisperKitTranscriber.currentModel else {
            print("📝 Model already matches stored preference: \(storedModel)")
            return
        }
        
        print("🔄 Applying stored model after onboarding: \(storedModel)")
        Task {
            do {
                try await audioManager.whisperKitTranscriber.switchModel(to: storedModel)
                print("✅ Successfully switched to stored model: \(storedModel)")
            } catch {
                print("❌ Failed to switch to stored model: \(error)")
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
                    print("❌ Failed to download update: \(error)")
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
        // Activate this instance when requested by another instance
        NSApp.activate(ignoringOtherApps: true)
        
        // Show the popover
        if let button = statusItem?.button {
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    // MARK: - Single Instance Management
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When app is activated (dock click, reopen), show the popover
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
        // Get all running instances of this app
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
        
        // Activate the first existing instance
        if let existingInstance = existingInstances.first {
            existingInstance.activate(options: .activateIgnoringOtherApps)
            
            // Send a notification to the existing instance to show its interface
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
    }
}
