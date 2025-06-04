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
        
        print("✅ Found caret at: \(screenRect)")
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
    @State private var waveOffset: Double = 0
    @State private var particleOffset: Double = 0
    @State private var glowIntensity: Double = 1.0
    @State private var flowDirection: Double = 0
    
    var body: some View {
        ZStack {
            // Central caret glow - precise and bright
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.white.opacity(0.9),
                            Color.blue.opacity(0.8),
                            Color.purple.opacity(0.6),
                            Color.clear
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3, height: 16)
                .blur(radius: 0.5)
                .opacity(glowIntensity)
                .shadow(color: .blue.opacity(0.8), radius: 5, x: 0, y: 0)
            
            // Dense particle swarm around caret
            ForEach(0..<25, id: \.self) { index in
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.8),
                                Color.blue.opacity(0.6),
                                Color.purple.opacity(0.4),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: 1.5
                        )
                    )
                    .frame(width: CGFloat.random(in: 1...2.5), height: CGFloat.random(in: 1...2.5))
                    .offset(
                        x: sin(particleOffset * 1.5 + Double(index) * 0.3) * 20 + cos(Double(index) * 2) * 6,
                        y: cos(particleOffset * 1.2 + Double(index) * 0.4) * 12 + sin(Double(index) * 3) * 4
                    )
                    .opacity(sin(particleOffset * 1.8 + Double(index) * 0.2) * 0.4 + 0.7)
                    .blur(radius: 0.2)
            }
            
            // Concentrated energy streams
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.blue.opacity(0.6),
                                Color.purple.opacity(0.8),
                                Color.pink.opacity(0.5),
                                Color.clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 20, height: 1.5)
                    .offset(
                        x: sin(flowDirection + Double(index) * 0.4) * 8,
                        y: sin(waveOffset + Double(index) * 0.6) * 4
                    )
                    .opacity(sin(waveOffset + Double(index) * 0.3) * 0.4 + 0.6)
                    .blur(radius: 0.5)
            }
            
            // Micro sparkles - very concentrated
            ForEach(0..<18, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 0.8, height: 0.8)
                    .offset(
                        x: sin(particleOffset * 2.2 + Double(index) * 0.5) * 15 + cos(Double(index) * 4) * 4,
                        y: cos(particleOffset * 2.0 + Double(index) * 0.6) * 10 + sin(Double(index) * 5) * 3
                    )
                    .opacity(sin(particleOffset * 2.5 + Double(index) * 0.4) * 0.5 + 0.8)
                    .scaleEffect(sin(particleOffset * 1.8 + Double(index)) * 0.6 + 1.2)
            }
            
            // Concentrated magical wisps
            ForEach(0..<10, id: \.self) { index in
                Image(systemName: "sparkle")
                    .font(.system(size: CGFloat.random(in: 2...4)))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [.white, .cyan, .blue]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .offset(
                        x: sin(particleOffset * 0.9 + Double(index) * 0.8) * 22 + cos(Double(index) * 2.2) * 8,
                        y: cos(particleOffset * 1.3 + Double(index) * 0.6) * 15 + sin(Double(index) * 1.7) * 6
                    )
                    .opacity(sin(particleOffset * 1.6 + Double(index) * 0.3) * 0.5 + 0.7)
                    .rotationEffect(.degrees(particleOffset * 40 + Double(index) * 36))
                    .scaleEffect(sin(particleOffset * 1.1 + Double(index) * 0.7) * 0.5 + 1.0)
            }
        }
        .frame(width: 60, height: 60)
        .onAppear {
            startMagicalAnimations()
        }
    }
    
    private func startMagicalAnimations() {
        // Flowing wave animation
        withAnimation(
            .linear(duration: 2.0)
            .repeatForever(autoreverses: false)
        ) {
            waveOffset = Double.pi * 4
        }
        
        // Particle movement animation
        withAnimation(
            .linear(duration: 8.0)
            .repeatForever(autoreverses: false)
        ) {
            particleOffset = Double.pi * 8
        }
        
        // Glow pulsing animation
        withAnimation(
            .easeInOut(duration: 1.5)
            .repeatForever(autoreverses: true)
        ) {
            glowIntensity = 0.3
        }
        
        // Flow direction animation
        withAnimation(
            .linear(duration: 6.0)
            .repeatForever(autoreverses: false)
        ) {
            flowDirection = Double.pi * 4
        }
    }
}

@MainActor
class RecordingIndicatorManager: ObservableObject {
    private var indicatorWindow: RecordingIndicatorWindow?
    
    func showIndicator() {
        hideIndicator() // Hide any existing indicator first
        
        indicatorWindow = RecordingIndicatorWindow()
        indicatorWindow?.showNearCaret()
    }
    
    func hideIndicator() {
        indicatorWindow?.hide()
        indicatorWindow = nil
    }
}
