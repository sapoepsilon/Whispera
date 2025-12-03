import AppKit
import SwiftUI

@MainActor
class LiveTranscriptionWindow: NSWindow {
	private let whisperKit = WhisperKitTranscriber.shared
	private let audioManager: AudioManager
	private var observationTimer: Timer?
	private var lastCaretPosition: NSPoint?
	private var lastTextContent: String = ""

	@AppStorage("liveTranscriptionWindowOffset") private var windowOffset = 25.0
	@AppStorage("liveTranscriptionMaxWidthPercentage") private var maxWidthPercentage = 0.6
	@AppStorage("liveTranscriptionFollowCaret") private var followCaret = true
	@AppStorage("showLiveTranscriptionWindow") private var showLiveTranscriptionWindow = true

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),  //TODO: make it customizeable
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

		self.center()

		let hostingView = NSHostingView(rootView: DictationView(audioManager: audioManager))
		self.contentView = hostingView

		setupObservation()
		setupCaretTracking()
	}

	deinit {
		observationTimer?.invalidate()
		Task { @MainActor in
			AccessibilityHelper.onCaretChange = nil
		}
	}

	private func setupObservation() {
		observationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }

				let shouldShow =
					self.showLiveTranscriptionWindow
					&& self.whisperKit.shouldShowLiveTranscriptionWindow
					&& self.whisperKit.isTranscribing

				if shouldShow {
					let newSize = self.calculateDynamicSize()

					if !self.isVisible {
						self.positionNearCaret(size: newSize)
						self.makeKeyAndOrderFront(nil)
					} else {
						if self.followCaret {
							_ = AccessibilityHelper.getCaretPosition()
						}

						if let currentCaretPosition = AccessibilityHelper.getCaretPosition() {
							if let lastPosition = self.lastCaretPosition {
								let distance = sqrt(
									pow(currentCaretPosition.x - lastPosition.x, 2)
										+ pow(currentCaretPosition.y - lastPosition.y, 2))

								if distance > 50 {
									self.positionRelativeToCaret(
										caretPosition: currentCaretPosition, windowSize: newSize)
								}
							}
							self.lastCaretPosition = currentCaretPosition
						}

						let pendingText = self.whisperKit.stableDisplayText

						if pendingText != self.lastTextContent {
							self.updateWindowSize(newSize)
							self.lastTextContent = pendingText
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
		let pendingText = whisperKit.stableDisplayText

		if pendingText.isEmpty {
			return NSSize(width: 120, height: 36)
		}

		let screen = screenForWindow()
		let screenWidth = screen.visibleFrame.width
		let screenBasedMaxWidth = screenWidth * maxWidthPercentage

		let words = pendingText.split(separator: " ")
		let lastWordWidth = words.last.map { CGFloat($0.count) * 10 } ?? 0
		let otherWordsWidth = words.dropLast().reduce(0) { $0 + CGFloat($1.count) * 7 }
		let spacesWidth = CGFloat(max(0, words.count - 1)) * 4

		let estimatedTextWidth = lastWordWidth + otherWordsWidth + spacesWidth
		let paddedWidth = estimatedTextWidth + 32
		let minWidth: CGFloat = 120
		let maxWidth = min(screenBasedMaxWidth, 800)
		let finalWidth = min(maxWidth, max(minWidth, paddedWidth))
		let finalHeight: CGFloat = 36

		return NSSize(width: finalWidth, height: finalHeight)
	}

	private func screenForWindow() -> NSScreen {
		if let caretPosition = lastCaretPosition {
			let screen = screenContaining(point: caretPosition)
			return screen
		}

		if self.isVisible {
			let windowCenter = NSPoint(x: frame.midX, y: frame.midY)
			let screen = screenContaining(point: windowCenter)
			return screen
		}

		let screen = NSScreen.main ?? NSScreen.screens.first!
		return screen
	}

	private func screenContaining(point: NSPoint) -> NSScreen {
		for screen in NSScreen.screens {
			if screen.frame.contains(point) {
				return screen
			}
		}
		return NSScreen.main ?? NSScreen.screens.first!
	}

	private func positionNearCaret(size: NSSize) {
		if let caretPosition = AccessibilityHelper.getCaretPosition() {
			lastCaretPosition = caretPosition
			positionRelativeToCaret(caretPosition: caretPosition, windowSize: size)
		} else {
			positionAtBottomCenter(size: size)
		}
	}

	private func positionRelativeToCaret(caretPosition: NSPoint, windowSize: NSSize) {
		let screen = screenContaining(point: caretPosition)
		let screenFrame = screen.visibleFrame

		let halfScreenHeight = screenFrame.height / 2
		let screenCenterY = screenFrame.origin.y + halfScreenHeight

		var windowX: CGFloat
		var windowY: CGFloat

		windowX = caretPosition.x - (windowSize.width / 2)

		let minX = screenFrame.origin.x + 20
		let maxX = screenFrame.origin.x + screenFrame.width - windowSize.width - 20

		windowX = max(minX, windowX)
		windowX = min(maxX, windowX)

		if caretPosition.y > screenCenterY {
			windowY = caretPosition.y - windowSize.height - windowOffset

			if windowY < screenFrame.origin.y + 10 {
				windowY = caretPosition.y + (windowOffset * 0.6)
			}
		} else {
			windowY = caretPosition.y + (windowOffset * 0.4)

			if windowY + windowSize.height > screenFrame.origin.y + screenFrame.height - 10 {
				windowY = caretPosition.y - windowSize.height - (windowOffset * 0.6)
			}
		}

		windowY = max(screenFrame.origin.y + 20, windowY)
		windowY = min(screenFrame.origin.y + screenFrame.height - windowSize.height - 20, windowY)

		let newFrame = NSRect(
			x: windowX, y: windowY, width: windowSize.width, height: windowSize.height)

		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			context.allowsImplicitAnimation = true
			self.animator().setFrame(newFrame, display: true)
		}
	}

	private func positionAtBottomCenter(size: NSSize) {
		let screen = screenForWindow()
		let screenFrame = screen.visibleFrame
		let windowX = screenFrame.origin.x + (screenFrame.width - size.width) / 2
		let bottomOffset = screenFrame.height * 0.1
		let windowY = screenFrame.origin.y + bottomOffset

		let newFrame = NSRect(x: windowX, y: windowY, width: size.width, height: size.height)

		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			context.allowsImplicitAnimation = true
			self.animator().setFrame(newFrame, display: true)
		}
	}

	private func centerOnScreen(size: NSSize) {
		positionAtBottomCenter(size: size)
	}

	private func updateWindowSize(_ newSize: NSSize) {
		let currentFrame = self.frame

		let widthDiff = abs(newSize.width - currentFrame.width)
		let heightDiff = abs(newSize.height - currentFrame.height)

		if widthDiff < 10 && heightDiff < 5 {
			return
		}

		if let caretPosition = lastCaretPosition {
			positionRelativeToCaret(caretPosition: caretPosition, windowSize: newSize)
		} else {
			positionAtBottomCenter(size: newSize)
		}
	}

	private func setupCaretTracking() {
		AccessibilityHelper.onCaretChange = { [weak self] newCaretPosition in
			guard let self = self else { return }

			if let caretPosition = newCaretPosition {
				self.lastCaretPosition = caretPosition

				if self.followCaret && self.isVisible && self.whisperKit.isTranscribing {
					let windowSize = self.calculateDynamicSize()
					self.positionRelativeToCaret(caretPosition: caretPosition, windowSize: windowSize)
				}
			}
		}
	}
}
