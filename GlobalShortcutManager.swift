import Foundation
import Cocoa
import ApplicationServices

class GlobalShortcutManager: ObservableObject {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var commandGlobalMonitor: Any?
    private var commandLocalMonitor: Any?
    private var audioManager: AudioManager?
	var currentShortcut: String = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"
	var currentCommandShortcut: String = UserDefaults.standard.string(forKey: "globalCommandShortcut") ?? "⌘⌥C"
	
    init() {
        setupShortcut()
        
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let newShortcut = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"
            let newCommandShortcut = UserDefaults.standard.string(forKey: "globalCommandShortcut") ?? "⌘⌥C"
            
            if newShortcut != self?.currentShortcut || newCommandShortcut != self?.currentCommandShortcut {
                print("🔄 Shortcuts changed - Text: \(self?.currentShortcut ?? "nil") → \(newShortcut), Command: \(self?.currentCommandShortcut ?? "nil") → \(newCommandShortcut)")
                self?.currentShortcut = newShortcut
                self?.currentCommandShortcut = newCommandShortcut
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
        if let monitor = commandGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            self.commandGlobalMonitor = nil
            print("🗑️ Removed old command global monitor")
        }
        if let monitor = commandLocalMonitor {
            NSEvent.removeMonitor(monitor)
            self.commandLocalMonitor = nil
            print("🗑️ Removed old command local monitor")
        }
        
        // Setup text shortcut
        let (modifiers, keyCode) = parseShortcut(currentShortcut)
        print("🎹 Setting up text shortcut for \(currentShortcut) (keyCode: \(keyCode), modifiers: \(modifiers.rawValue))")
        
        // Setup command shortcut
        let (commandModifiers, commandKeyCode) = parseShortcut(currentCommandShortcut)
        print("🎹 Setting up command shortcut for \(currentCommandShortcut) (keyCode: \(commandKeyCode), modifiers: \(commandModifiers.rawValue))")
        
        // Set up global monitors (works when other apps are focused)
        print("🌍 Installing global monitors...")
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesShortcut(event: event, expectedModifiers: modifiers, expectedKeyCode: keyCode) == true {
                print("🎯 Global text shortcut detected!")
				self?.handleTextHotKey()
            } else if self?.matchesShortcut(event: event, expectedModifiers: commandModifiers, expectedKeyCode: commandKeyCode) == true {
                print("🎯 Global command shortcut detected!")
				self?.handleCommandHotKey()
            }
        }
        
        // Also set up local monitors as fallback (works when app is focused)
        print("🏠 Installing local monitors as fallback...")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesShortcut(event: event, expectedModifiers: modifiers, expectedKeyCode: keyCode) == true {
                print("🎯 Local text shortcut detected!")
				self?.handleTextHotKey()
                return nil // Consume the event
            } else if self?.matchesShortcut(event: event, expectedModifiers: commandModifiers, expectedKeyCode: commandKeyCode) == true {
                print("🎯 Local command shortcut detected!")
				self?.handleCommandHotKey()
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
        
        // Extract the key character (last character that's not a modifier)
        for char in shortcut.reversed() {
            if !"⌘⌥⌃⇧".contains(char) {
                keyChar = String(char)
                break
            }
        }
        
        let keyCode = keyCodeForCharacter(keyChar.lowercased())
        print("🔍 Parsed: keyChar='\(keyChar)', keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
        return (modifiers, keyCode)
    }
    
    private func keyCodeForCharacter(_ char: String) -> UInt16 {
        // Map common characters to key codes
        switch char.lowercased() {
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
			audioManager?.toggleRecording(mode: .text)
        }
    }
	
	private func handleCommandHotKey() {
        Task { @MainActor in
			audioManager?.toggleRecording(mode: .command)
        }
    }
    
    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = commandGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = commandLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
