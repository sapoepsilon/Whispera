import SwiftUI
import AppKit

@MainActor
class LiveTranscriptionWindow: NSWindow {
    private let whisperKit = WhisperKitTranscriber.shared
    private var observationTimer: Timer?
    private var lastCaretPosition: NSPoint?
    private var lastTextContent: String = ""
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
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
        
        // Initially center on screen (fallback position)
        self.center()
        
        let hostingView = NSHostingView(rootView: LiveTranscriptionView())
        self.contentView = hostingView
        
        // Observe changes in whisperKit to show/hide and position window
        setupObservation()
    }
    
    deinit {
        observationTimer?.invalidate()
    }
    
    private func setupObservation() {
        // Check for visibility, positioning, and repositioning changes
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Always show when transcribing, regardless of text length
                let shouldShow = self.whisperKit.shouldShowWindow && 
                               self.whisperKit.isTranscribing
                
                if shouldShow {
                    // Calculate dynamic window size based on content
                    let newSize = self.calculateDynamicSize()
                    
                    if !self.isVisible {
                        // Position window intelligently near caret
                        self.positionNearCaret(size: newSize)
                        self.makeKeyAndOrderFront(nil)
                    } else {
                        // Check if we need to reposition (user focused on different input)
                        if let currentCaretPosition = AccessibilityHelper.getCaretPosition(),
                           let lastPosition = self.lastCaretPosition {
                            
                            // If caret moved significantly (more than 50px), reposition window
                            let distance = sqrt(pow(currentCaretPosition.x - lastPosition.x, 2) + 
                                              pow(currentCaretPosition.y - lastPosition.y, 2))
                            
                            if distance > 50 {
                                print("🔄 Caret moved significantly, repositioning window")
                                self.positionRelativeToCaret(caretPosition: currentCaretPosition, windowSize: newSize)
                                self.lastCaretPosition = currentCaretPosition
                            }
                        }
                        
                        // Update size if recent words changed significantly
                        let words = self.whisperKit.currentText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        let filteredWords = words.filter { word in
                            !word.lowercased().contains("waiting") && 
                            !word.lowercased().contains("listening") &&
                            !word.lowercased().contains("speech")
                        }
                        let recentWords = filteredWords.suffix(8).joined(separator: " ")
                        
                        if recentWords != self.lastTextContent {
                            self.updateWindowSize(newSize)
                            self.lastTextContent = recentWords
                        }
                    }
                } else {
                    if self.isVisible {
                        self.orderOut(nil)
                        self.lastTextContent = ""
                    }
                }
            }
        }
    }
    
    private func calculateDynamicSize() -> NSSize {
        let currentContent = whisperKit.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter out WhisperKit's default messages
        if currentContent.isEmpty || 
           currentContent.contains("Waiting for speech") ||
           currentContent.contains("Listening") ||
           currentContent.contains("waiting for speech") ||
           currentContent.contains("listening") {
            // Minimal size for "Listening..." state
            return NSSize(width: 120, height: 32)
        }
        
        // We only show the last 8 words, so calculate size based on that
        let words = currentContent.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let filteredWords = words.filter { word in
            !word.lowercased().contains("waiting") && 
            !word.lowercased().contains("listening") &&
            !word.lowercased().contains("speech")
        }
        let recentWords = filteredWords.suffix(8)
        let displayText = recentWords.joined(separator: " ")
        
        if displayText.isEmpty {
            return NSSize(width: 120, height: 32)
        }
        
        // Estimate width: average 7 characters per word + spaces, plus padding
        let estimatedTextWidth = CGFloat(displayText.count) * 7
        let paddedWidth = estimatedTextWidth + 32 // 16pt padding on each side
        
        // Constrain width - keep it reasonable since we only show recent words
        let minWidth: CGFloat = 120
        let maxWidth: CGFloat = 300 // Smaller max since we show fewer words
        let finalWidth = min(maxWidth, max(minWidth, paddedWidth))
        
        // Height for up to 2 lines (since lineLimit is 2)
        let baseHeight: CGFloat = 32
        let lineHeight: CGFloat = 20
        
        // Rough estimate: if text is longer than ~40 chars, it'll wrap to 2 lines
        let estimatedLines = displayText.count > 40 ? 2 : 1
        let finalHeight = baseHeight + CGFloat(max(0, estimatedLines - 1)) * lineHeight
        
        return NSSize(width: finalWidth, height: finalHeight)
    }
    
    private func positionNearCaret(size: NSSize) {
        // Try to get caret position using accessibility API
        if let caretPosition = AccessibilityHelper.getCaretPosition() {
            lastCaretPosition = caretPosition
            positionRelativeToCaret(caretPosition: caretPosition, windowSize: size)
        } else {
            // Fallback: Use last known position or center
            if let lastPosition = lastCaretPosition {
                positionRelativeToCaret(caretPosition: lastPosition, windowSize: size)
            } else {
                centerOnScreen(size: size)
            }
        }
    }
    
    private func positionRelativeToCaret(caretPosition: NSPoint, windowSize: NSSize) {
        guard let screen = NSScreen.main else {
            centerOnScreen(size: windowSize)
            return
        }
        
        let screenFrame = screen.visibleFrame
        let halfScreenHeight = screenFrame.height / 2
        let screenCenterY = screenFrame.origin.y + halfScreenHeight
        
        var windowX: CGFloat
        var windowY: CGFloat
        
        // Horizontal positioning: try to stay near caret, but keep fully visible
        windowX = caretPosition.x - (windowSize.width / 2)
        
        // Keep window within screen bounds horizontally
        windowX = max(screenFrame.origin.x + 20, windowX)
        windowX = min(screenFrame.origin.x + screenFrame.width - windowSize.width - 20, windowX)
        
        // Vertical positioning: smart placement based on screen position
        if caretPosition.y > screenCenterY {
            // Caret in upper half of screen: position window below caret
            windowY = caretPosition.y - windowSize.height - 40
            
            // Ensure window doesn't go below screen
            if windowY < screenFrame.origin.y + 20 {
                windowY = caretPosition.y + 30 // Position above caret instead
            }
        } else {
            // Caret in lower half of screen: position window above caret
            windowY = caretPosition.y + 30
            
            // Ensure window doesn't go above screen
            if windowY + windowSize.height > screenFrame.origin.y + screenFrame.height - 20 {
                windowY = caretPosition.y - windowSize.height - 40 // Position below caret instead
            }
        }
        
        // Final bounds check
        windowY = max(screenFrame.origin.y + 20, windowY)
        windowY = min(screenFrame.origin.y + screenFrame.height - windowSize.height - 20, windowY)
        
        let newFrame = NSRect(x: windowX, y: windowY, width: windowSize.width, height: windowSize.height)
        
        print("🎯 Positioning window at caret: \(caretPosition) → window: \(newFrame)")
        
        // Animate the positioning
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }
    }
    
    private func centerOnScreen(size: NSSize) {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let windowX = screenFrame.origin.x + (screenFrame.width - size.width) / 2
        let windowY = screenFrame.origin.y + (screenFrame.height - size.height) / 2
        
        let newFrame = NSRect(x: windowX, y: windowY, width: size.width, height: size.height)
        
        print("📍 Centering window on screen: \(newFrame)")
        
        // Animate to center
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }
    }
    
    private func updateWindowSize(_ newSize: NSSize) {
        let currentFrame = self.frame
        
        // Only update if size actually changed significantly
        let widthDiff = abs(newSize.width - currentFrame.width)
        let heightDiff = abs(newSize.height - currentFrame.height)
        
        if widthDiff < 10 && heightDiff < 5 {
            return // Don't animate tiny changes
        }
        
        // Keep same position, just update size (grow from bottom-left)
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y - (newSize.height - currentFrame.height), // Adjust Y to grow upward
            width: newSize.width,
            height: newSize.height
        )
        
        // Fast, subtle animation for size changes
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }
    }
}
