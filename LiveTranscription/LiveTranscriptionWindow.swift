import SwiftUI
import AppKit

@MainActor
class LiveTranscriptionWindow: NSWindow {
    private let whisperKit = WhisperKitTranscriber.shared
    private var observationTimer: Timer?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
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
        
        // Center on screen
        self.center()
        
        let hostingView = NSHostingView(rootView: LiveTranscriptionView())
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
                
                if self.whisperKit.shouldShowWindow && !self.whisperKit.pendingText.isEmpty {
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
