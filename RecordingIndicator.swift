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
        
        self.level = .floatingWindow
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.canBecomeKey = false
        self.canBecomeMain = false
        self.isMovable = false
        self.ignoresMouseEvents = true
        
        let hostingView = NSHostingView(rootView: RecordingIndicatorView())
        self.contentView = hostingView
    }
    
    func showNearCursor() {
        // Get current cursor position
        let mouseLocation = NSEvent.mouseLocation
        
        // Position the window near the cursor but not blocking it
        let windowFrame = NSRect(
            x: mouseLocation.x + 20,
            y: mouseLocation.y - 30,
            width: 60,
            height: 60
        )
        
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
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Background circle with blur
            Circle()
                .fill(.regularMaterial)
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            
            // Microphone icon
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)
                .scaleEffect(isAnimating ? 1.2 : 1.0)
                .opacity(isAnimating ? 0.8 : 1.0)
        }
        .background(
            // Pulsing ring
            Circle()
                .stroke(Color.blue, lineWidth: 2)
                .scaleEffect(isAnimating ? 1.5 : 1.0)
                .opacity(isAnimating ? 0.0 : 0.8)
                .frame(width: 50, height: 50)
        )
        .onAppear {
            startPulseAnimation()
        }
    }
    
    private func startPulseAnimation() {
        withAnimation(
            .easeInOut(duration: 1.0)
            .repeatForever(autoreverses: true)
        ) {
            isAnimating = true
        }
    }
}

@MainActor
class RecordingIndicatorManager: ObservableObject {
    private var indicatorWindow: RecordingIndicatorWindow?
    
    func showIndicator() {
        hideIndicator() // Hide any existing indicator first
        
        indicatorWindow = RecordingIndicatorWindow()
        indicatorWindow?.showNearCursor()
    }
    
    func hideIndicator() {
        indicatorWindow?.hide()
        indicatorWindow = nil
    }
}