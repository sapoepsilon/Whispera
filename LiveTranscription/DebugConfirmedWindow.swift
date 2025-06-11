import SwiftUI
import AppKit

@MainActor
class DebugConfirmedWindow: NSWindow {
    private let whisperKit = WhisperKitTranscriber.shared
    private var observationTimer: Timer?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = true
        self.ignoresMouseEvents = false
		self.isMovableByWindowBackground = true
        // Position below center for debug info
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowFrame = self.frame
        let x = (screenFrame.width - windowFrame.width) / 2
        let y = (screenFrame.height - windowFrame.height) / 2 - 150 // Below center
        self.setFrameOrigin(NSPoint(x: x, y: y))
        
        let hostingView = NSHostingView(rootView: DebugConfirmedView())
        self.contentView = hostingView
        
        // Observe changes in whisperKit to show/hide window
        setupObservation()
    }
    
    deinit {
        observationTimer?.invalidate()
    }
    
    private func setupObservation() {
        // Use timer-based observation for now
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                if self.whisperKit.shouldShowDebugWindow {
                    if !self.isVisible {
                        self.makeKeyAndOrderFront(nil)
                    }
                } else {
                    if self.isVisible {
                        self.orderOut(nil)
                    }
                }
            }
        }
    }
}
