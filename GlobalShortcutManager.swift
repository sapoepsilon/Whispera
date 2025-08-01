import Foundation
import Cocoa
import ApplicationServices

class GlobalShortcutManager: ObservableObject {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var audioManager: AudioManager?
	var currentShortcut: String = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"

    init() {
        setupShortcut()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let newShortcut = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"
            if newShortcut != self?.currentShortcut {
                print("🔄 Shortcut changed - Text: \(self?.currentShortcut ?? "nil") → \(newShortcut)")
                self?.currentShortcut = newShortcut
                self?.setupShortcut()
            }
        }
    }

    func setAudioManager(_ manager: AudioManager) {
        self.audioManager = manager
        print("🔗 AudioManager set, checking accessibility status...")
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        let hasPermissions = AXIsProcessTrusted()
        print("🔐 Current accessibility permissions: \(hasPermissions)")
        print("🎯 Current shortcut: \(currentShortcut)")
        print("🎛️ Global monitor active: \(globalMonitor != nil)")

        if !hasPermissions {
            print("⚠️ PROBLEM: No accessibility permissions - shortcuts will NOT work")
            print("💡 Go to System Settings > Privacy & Security > Accessibility")
            print("💡 Add Whispera to the list and enable it")
        } else if globalMonitor == nil {
            print("⚠️ PROBLEM: Global monitor not set up despite having permissions")
            setupShortcut()
        }
    }

    private func setupShortcut() {
        print("🔧 setupShortcut() called")

        // Remove existing monitors
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMonitor = nil
            print("🗑️ Removed old global monitor")
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
            print("🗑️ Removed old local monitor")
        }

        // Setup text shortcut
        let (modifiers, keyCode) = parseShortcut(currentShortcut)
        print("🎹 Setting up text shortcut for \(currentShortcut) (keyCode: \(keyCode), modifiers: \(modifiers.rawValue))")

        // Set up global monitors (works when other apps are focused)
        print("🌍 Installing global monitors...")
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesShortcut(event: event, expectedModifiers: modifiers, expectedKeyCode: keyCode) == true {
                print("🎯 Global text shortcut detected!")
                self?.handleTextHotKey()
            }
        }

        // Also set up local monitors as fallback (works when app is focused)
        print("🏠 Installing local monitors as fallback...")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesShortcut(event: event, expectedModifiers: modifiers, expectedKeyCode: keyCode) == true {
                print("🎯 Local text shortcut detected!")
				self?.handleTextHotKey()
                return nil // Consume the event
            }
            return event
        }

        print("✅ Monitors installed - Global: \(globalMonitor != nil), Local: \(localMonitor != nil)")
    }

    private func parseShortcut(_ shortcut: String) -> (NSEvent.ModifierFlags, UInt16) {
        var modifiers: NSEvent.ModifierFlags = []
        var keyChar = ""

        print("🔍 Parsing shortcut: '\(shortcut)'")

        if shortcut.contains("⌘") { modifiers.insert(.command) }
        if shortcut.contains("⌥") { modifiers.insert(.option) }
        if shortcut.contains("⌃") { modifiers.insert(.control) }
        if shortcut.contains("⇧") { modifiers.insert(.shift) }

        // Extract the key character (everything after modifiers)
        let modifierSymbols = "⌘⌥⌃⇧"
        var remainingShortcut = shortcut

        // Remove all modifier symbols from the beginning
        for symbol in modifierSymbols {
            remainingShortcut = remainingShortcut.replacingOccurrences(of: String(symbol), with: "")
        }

        keyChar = remainingShortcut.trimmingCharacters(in: .whitespaces)

        let keyCode = keyCodeForCharacter(keyChar.lowercased())
        print("🔍 Parsed: keyChar='\(keyChar)', keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
        return (modifiers, keyCode)
    }

    private func keyCodeForCharacter(_ char: String) -> UInt16 {
        // Map common characters and special keys to key codes
        switch char.lowercased() {
        // Letters
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6

        // Numbers
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25

        // Function keys
		case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        case "f13": return 105
        case "f14": return 107
        case "f15": return 113
        case "f16": return 106
        case "f17": return 64
        case "f18": return 79
        case "f19": return 80
        case "f20": return 90

        // Special keys
        case "space", " ": return 49
        case "return", "enter", "↩": return 36
        case "tab", "⇥": return 48
        case "delete", "⌫": return 51
        case "escape", "esc", "⎋": return 53
        case "home", "↖": return 115
        case "end", "↘": return 119
        case "pageup", "⇞": return 116
        case "pagedown", "⇟": return 121
        case "up", "↑": return 126
        case "down", "↓": return 125
        case "left", "←": return 123
        case "right", "→": return 124
        case "clear", "⌧": return 71
        case "help", "?⃝": return 114

        // Punctuation
        case "-": return 27
        case "=": return 24
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case ";": return 41
        case "'": return 39
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case "`": return 50

        // Globe/Fn key (on newer Macs)
        case "globe", "fn", "🌐": return 63

        default: return 15 // Default to 'R' key
        }
    }

    private func matchesShortcut(event: NSEvent, expectedModifiers: NSEvent.ModifierFlags, expectedKeyCode: UInt16) -> Bool {
        return event.modifierFlags.intersection([.command, .option, .control, .shift]) == expectedModifiers &&
               event.keyCode == expectedKeyCode
    }

    func requestAccessibilityPermissions() {
        print("🔐 Requesting accessibility permissions...")
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            print("✅ Accessibility permissions granted, setting up shortcut")
            setupShortcut()
        } else {
            print("⏳ Waiting for accessibility permissions...")
            print("📱 Please go to System Settings > Privacy & Security > Accessibility and enable Whispera")
            print("💡 Global shortcuts will NOT work until accessibility permissions are granted")

            // Check again every 3 seconds for up to 30 seconds
            var checkCount = 0
            let maxChecks = 10

            func checkPermissions() {
                checkCount += 1
                if AXIsProcessTrusted() {
                    print("✅ Accessibility permissions now granted! Setting up global shortcuts...")
                    self.setupShortcut()
                } else if checkCount < maxChecks {
                    print("⏳ Still waiting for accessibility permissions... (\(checkCount)/\(maxChecks))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        checkPermissions()
                    }
                } else {
                    print("⚠️ Accessibility permissions still not granted. Global shortcuts disabled.")
                    print("💡 You can grant permissions later in System Settings > Privacy & Security > Accessibility")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                checkPermissions()
            }
        }
    }

	private func handleTextHotKey() {
        Task { @MainActor in
            // Check if haptic feedback is enabled
            if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
				NSHapticFeedbackManager.defaultPerformer
					.perform(.levelChange, performanceTime: .now)
            }
			audioManager?.toggleRecording()
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
