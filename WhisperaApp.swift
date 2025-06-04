import SwiftUI
import AppKit

@main
struct WhisperaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var audioManager: AudioManager!
    var shortcutManager: GlobalShortcutManager!
    @AppStorage("globalShortcut") var globalShortcut = "⌘⌥D"
    private var recordingObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDefaultsIfNeeded()
        
        Task { @MainActor in
            audioManager = AudioManager()
            shortcutManager = GlobalShortcutManager()
            setupMenuBar()
            NSApp.setActivationPolicy(.accessory)
            shortcutManager.setAudioManager(audioManager)
            observeRecordingState()
        }
    }
    
    private func setupDefaultsIfNeeded() {
        // Set default values if they don't exist
        if UserDefaults.standard.object(forKey: "selectedModel") == nil {
            UserDefaults.standard.set("openai_whisper-small.en", forKey: "selectedModel")
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
    
    deinit {
        if let observer = recordingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
