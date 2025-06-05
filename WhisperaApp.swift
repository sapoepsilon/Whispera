import SwiftUI
import AppKit

@main
struct WhisperaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Whispera") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Whispera",
                            .applicationVersion: "1.0"
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
    @AppStorage("globalShortcut") var globalShortcut = "⌥⌘R"
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    private var recordingObserver: NSObjectProtocol?
    private var onboardingWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDefaultsIfNeeded()
        
        Task { @MainActor in
            audioManager = AudioManager()
            shortcutManager = GlobalShortcutManager()
            setupMenuBar()
            NSApp.setActivationPolicy(.accessory)
            shortcutManager.setAudioManager(audioManager)
            observeRecordingState()
            observeWindowState()
            
            // Show onboarding if first launch
            if !hasCompletedOnboarding {
                showOnboarding()
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
        
        popover.contentViewController = NSHostingController(rootView: MenuBarView(audioManager: audioManager))
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        onboardingWindow?.title = "Welcome to Whispera"
        onboardingWindow?.contentViewController = hostingController
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        
        // Set app policy to regular when showing onboarding
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Listen for onboarding completion
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("OnboardingCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            NSApp.setActivationPolicy(.accessory)
            
            // Switch to the selected model after onboarding completes
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
            if audioManager.isTranscribing {
                // Transcribing state - blue waveform icon following design language
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whispera - Transcribing")
                button.image?.isTemplate = false
                button.contentTintColor = .systemBlue
                button.alphaValue = 1.0 // Reset alpha for transcribing state
            } else if audioManager.isRecording {
                // Recording state - listening waveform icon with animation
                button.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Whispera - Listening")
                button.image?.isTemplate = false
                button.contentTintColor = .systemRed
                
                // Add a subtle pulsing animation to show it's actively listening
                button.alphaValue = 1.0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 1.0
                    context.allowsImplicitAnimation = true
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    button.animator().alphaValue = 0.6
                } completionHandler: {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 1.0
                        context.allowsImplicitAnimation = true
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        button.animator().alphaValue = 1.0
                    }
                }
            } else {
                // Ready state - default microphone icon
                button.image = NSImage(systemSymbolName: "microphone", accessibilityDescription: "Whispera")
                button.image?.isTemplate = true
                button.contentTintColor = nil
                button.alphaValue = 1.0 // Reset alpha for normal state
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
    
    deinit {
        if let observer = recordingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
