import SwiftUI
import AppKit

@main
struct MacWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mac Whisper") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Mac Whisper",
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
    @AppStorage("globalShortcut") var globalShortcut = "⌘⇧R"
    private var recordingObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            audioManager = AudioManager()
            shortcutManager = GlobalShortcutManager()
            setupMenuBar()
            NSApp.setActivationPolicy(.accessory)
            shortcutManager.setAudioManager(audioManager)
            observeRecordingState()
        }
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Mac Whisper")
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
            if audioManager.isRecording {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mac Whisper - Recording")
                button.image?.isTemplate = false
                button.contentTintColor = .systemRed
            } else {
                button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Mac Whisper")
                button.image?.isTemplate = true
                button.contentTintColor = nil
            }
        }
    }
    
    deinit {
        if let observer = recordingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}