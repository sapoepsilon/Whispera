import AppKit
import ApplicationServices

/// Shared utility for accessibility-based caret position detection
@MainActor
class AccessibilityHelper {
    
    /// Get the current caret position in screen coordinates
    static func getCaretPosition() -> NSPoint? {
        // Check if we have accessibility permissions
        guard AXIsProcessTrusted() else {
            print("❌ App doesn't have accessibility permissions")
            return nil
        }
        
        // Try to get caret position using focused element
        return tryDirectFocusedElementMethod()
    }
    
    /// Request accessibility permissions if not already granted
    static func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        print("🔐 Accessibility permissions: \(trusted)")
    }
    
    /// Check if accessibility permissions are granted
    static func hasAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    // MARK: - Private Methods
    
    private static func tryDirectFocusedElementMethod() -> NSPoint? {
        let system = AXUIElementCreateSystemWide()
        var application: CFTypeRef?
        var focusedElement: CFTypeRef?
        
        // Step 1: Find the currently focused application
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &application) == .success else {
            print("❌ Could not get focused application")
            return nil
        }
        
        // Step 2: Find the currently focused UI Element in that application
        guard AXUIElementCopyAttributeValue(application! as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            print("❌ Could not get focused UI element")
            return nil
        }
        
        return getCaretFromElement(focusedElement! as! AXUIElement)
    }
    
    private static func getCaretFromElement(_ element: AXUIElement) -> NSPoint? {
        // Check if element has selection range attribute
        var rangeValueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValueRef) == .success else {
            return nil
        }
        
        let rangeValue = rangeValueRef! as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange) else {
            return nil
        }
        
        // Get screen bounds for the cursor position
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds) == .success else {
            return nil
        }
        
        var screenRect = CGRect.zero
        guard AXValueGetValue(bounds! as! AXValue, .cgRect, &screenRect) else {
            return nil
        }
        
        print("✅ Found caret at: \(screenRect)")
        return carbonToCocoa(carbonPoint: NSPoint(x: screenRect.origin.x, y: screenRect.origin.y))
    }
    
    private static func carbonToCocoa(carbonPoint: NSPoint) -> NSPoint {
        // Convert Carbon screen coordinates to Cocoa screen coordinates
        guard let mainScreen = NSScreen.main else {
            return carbonPoint
        }
        let screenHeight = mainScreen.frame.size.height
        return NSPoint(x: carbonPoint.x, y: screenHeight - carbonPoint.y)
    }
}
