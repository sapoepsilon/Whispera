import Foundation
import Cocoa
import OSAKit

/// Provides system context for command generation
class ContextProvider {
    static let shared = ContextProvider()
    
    private init() {}
    
    /// Get current system context for command generation
    func getCurrentContext() -> String {
        var context: [String] = []
        
        // Get current directory from Finder
        if let finderPath = getCurrentFinderPath() {
            context.append("Current directory: \(finderPath)")
        }
        
        // Get frontmost application
        if let frontmostApp = getFrontmostApplication() {
            context.append("Active application: \(frontmostApp)")
        }
        
        // Get current time
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        context.append("Current time: \(formatter.string(from: Date()))")
        
        return context.isEmpty ? "No additional context available" : context.joined(separator: "\n")
    }
    
    /// Get current Finder path using Accessibility API first, then AppleScript fallback
    private func getCurrentFinderPath() -> String? {
        // Try Accessibility API first
        if let accessibilityPath = getFinderPathViaAccessibility() {
            print("🔍 Got Finder path via Accessibility API: \(accessibilityPath)")
            return accessibilityPath
        }
        
        // Fallback to AppleScript
        if let applescriptPath = getFinderPathViaAppleScript() {
            print("🔍 Got Finder path via AppleScript: \(applescriptPath)")
            return applescriptPath
        }
        
        print("⚠️ Could not determine current Finder path")
        return nil
    }
    
    /// Get Finder path using Accessibility API
    private func getFinderPathViaAccessibility() -> String? {
        guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return nil
        }
        
        let finderElement = AXUIElementCreateApplication(finderApp.processIdentifier)
        
        // Get all windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(finderElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        
        // Find the frontmost Finder window
        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else {
                continue
            }
            
            // Skip special Finder windows
            if title.isEmpty || title == "Finder" || title.contains("Trash") {
                continue
            }
            
            // Convert title to path
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
            
            // Handle common Finder window titles
            switch title {
            case "Desktop":
                return "\(homeDirectory)/Desktop"
            case "Documents":
                return "\(homeDirectory)/Documents"
            case "Downloads":
                return "\(homeDirectory)/Downloads"
            case "Applications":
                return "/Applications"
            default:
                // For other titles, try to construct path
                if title.starts(with: "/") {
                    return title
                } else {
                    return "\(homeDirectory)/\(title)"
                }
            }
        }
        
        return nil
    }
    
    /// Get Finder path using AppleScript
    private func getFinderPathViaAppleScript() -> String? {
        let script = """
        tell application "Finder"
            try
                set currentFolder to folder of the front window as alias
                return POSIX path of currentFolder
            on error
                return POSIX path of (desktop as alias)
            end try
        end tell
        """
        
        let osascript = OSAScript(source: script)
        
        var error: NSDictionary?
        let result = osascript.executeAndReturnError(&error)
        
        if let error = error {
            print("❌ AppleScript error: \(error)")
            return nil
        }
        
        guard let stringValue = result?.stringValue else {
            return nil
        }
        
        let path = stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        return path.isEmpty ? nil : path
    }
    
    /// Get frontmost application name
    private func getFrontmostApplication() -> String? {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            return frontmostApp.localizedName
        }
        return nil
    }
}