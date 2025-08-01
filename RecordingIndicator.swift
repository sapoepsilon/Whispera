import SwiftUI
import AppKit

class RecordingIndicatorWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
		self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.ignoresMouseEvents = true
        
        let hostingView = NSHostingView(rootView: RecordingIndicatorView())
        self.contentView = hostingView
    }
    
    func showNearCaret() {
        print("📍 showNearCaret called")
        
        // Try to get the active text field/view insertion point
        let caretPosition = getCaretPosition()
        
        // If we can't find the caret, don't show the indicator
        if caretPosition == NSPoint.zero {
            print("❌ Could not find caret position - not showing indicator")
            return
        } else {
            print("✅ Using caret position: \(caretPosition)")
        }
        
        // Position the window precisely at the caret
        let windowFrame = NSRect(
            x: caretPosition.x - 30,
            y: caretPosition.y - 30,
            width: 60,
            height: 60
        )
        
        print("🪟 Setting window frame: \(windowFrame)")
        self.setFrame(windowFrame, display: true)
        self.orderFront(nil)
        
        // Animate in
        self.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
        }
    }
    
	private func getCaretPosition() -> NSPoint {
		print("🔍 Getting caret position using native-only detection...")
		
		// Check if we have accessibility permissions
		let trusted = AXIsProcessTrusted()
		if !trusted {
			print("❌ App doesn't have accessibility permissions!")
			let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
			let trustedWithPrompt = AXIsProcessTrustedWithOptions(options as CFDictionary)
			print("🔐 Requested accessibility permissions: \(trustedWithPrompt)")
			return NSPoint.zero
		}
		
		print("✅ App has accessibility permissions")
		
		// Only try exact caret position method
		
		// Get exact caret position using focused element
		if let position = tryDirectFocusedElementMethod() {
			return position
		}
		
		print("❌ Native caret detection failed - not showing indicator")
		return NSPoint.zero
	}
    private func tryDirectFocusedElementMethod() -> NSPoint? {
        print("🎯 Trying direct focused element method...")
        
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
    
    
    private func getCaretFromElement(_ element: AXUIElement) -> NSPoint? {
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
        
        return carbonToCocoa(carbonPoint: NSPoint(x: screenRect.origin.x, y: screenRect.origin.y))
    }
    
    private func carbonToCocoa(carbonPoint: NSPoint) -> NSPoint {
        // Convert Carbon screen coordinates to Cocoa screen coordinates
        guard let mainScreen = NSScreen.main else {
            return carbonPoint
        }
        let screenHeight = mainScreen.frame.size.height
        return NSPoint(x: carbonPoint.x, y: screenHeight - carbonPoint.y)
    }
    
    
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 0.0
        }) {
            self.orderOut(nil)
        }
    }
}

struct RecordingIndicatorView: View {
    @State private var pulseAnimation: Bool = false
    @State private var waveScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Outer pulse ring
            Circle()
                .stroke(.red.opacity(0.3), lineWidth: 2)
                .frame(width: 40, height: 40)
                .scaleEffect(waveScale)
                .opacity(0.8)
            
            // Background circle
            Circle()
                .fill(.red.opacity(0.8))
                .frame(width: 32, height: 32)
                .scaleEffect(pulseAnimation ? 1.05 : 1.0)
            
            // Main microphone icon with sound waves
            HStack(spacing: 2) {
                // Sound wave lines
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: pulseAnimation ? 8 : 4)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: pulseAnimation ? 12 : 6)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: pulseAnimation ? 6 : 3)
                }
                .opacity(0.8)
                
                // Microphone icon
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 60, height: 60)
        .onAppear {
            startListeningAnimation()
        }
    }
    
    private func startListeningAnimation() {
        // Gentle pulse animation
        withAnimation(
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: true)
        ) {
            pulseAnimation = true
        }
        
        // Subtle wave pulse
        withAnimation(
            .easeInOut(duration: 1.8)
            .repeatForever(autoreverses: true)
        ) {
            waveScale = 1.3
        }
    }
}

@MainActor
class RecordingIndicatorManager: ObservableObject {
    private var indicatorWindow: RecordingIndicatorWindow?
    
    func showIndicator() {
        hideIndicator()
        indicatorWindow = RecordingIndicatorWindow()
        indicatorWindow?.showNearCaret()
    }
    
    func hideIndicator() {
        indicatorWindow?.hide()
        indicatorWindow = nil
    }
}
	
