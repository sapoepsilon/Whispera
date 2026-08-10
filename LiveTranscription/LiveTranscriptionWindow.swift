import AppKit
import QuartzCore
import SwiftUI

/// The pill's overlay for transient live-session content: the emerging words,
/// a "waiting for model" status, or a post-dictation recipe error. It always
/// sits above the listening pill — see `PillAnchor` — growing upward as its
/// content grows, and never follows the caret: that used to be this window's
/// only positioning mode, but with the pill itself now visible in every
/// recording mode (see `RecordingWindowPolicy`), anchoring to the pill reads
/// as one continuous surface instead of two disagreeing ones. See WHI-58.
@MainActor
class LiveTranscriptionWindow: NSWindow {
	// The shared live state, not one engine: any engine that streams drives this
	// window. See WHI-58.
	private let live = LiveTranscriptionState.shared
	private let coordinator = DictationCoordinator.shared
	private let audioManager: AudioManager
	private var observationTimer: Timer?
	private var lastTextContent: String = ""

	@AppStorage("liveTranscriptionMaxWidthPercentage") private var maxWidthPercentage = 0.6

	init(audioManager: AudioManager) {
		self.audioManager = audioManager
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)

		self.level = .floating
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = true
		// Dragging the pill is how the user repositions this whole surface;
		// dragging the words themselves would just fight PillAnchor putting it
		// straight back above the pill on the next layout pass.
		self.isMovable = false
		self.ignoresMouseEvents = true

		self.center()

		let hostingView = NSHostingView(rootView: DictationView(audioManager: audioManager))
		self.contentView = hostingView

		setupObservation()
		observePillMovement()
	}

	deinit {
		observationTimer?.invalidate()
	}

	private func setupObservation() {
		observationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }

				// Keep the HUD up briefly after a recipe errors so the message is
				// readable. The running state itself lives in the listening pill.
				let recipeActive = self.coordinator.overlayError != nil
				let shouldShow =
					RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
						mode: self.audioManager.currentRecordingMode,
						transcriberWantsWindow: self.live.shouldShowLiveTranscriptionWindow
							&& (self.live.isTranscribing || self.live.isWaitingForModel)
					) || recipeActive

				if shouldShow {
					let newSize = self.calculateDynamicSize()

					if !self.isVisible {
						self.presentAbovePill(size: newSize)
					} else {
						let pendingText =
							self.live.isWaitingForModel
							? self.live.waitingForModelStatusText
							: self.live.stableDisplayText

						if pendingText != self.lastTextContent || self.isShowingRecipeError {
							self.updateWindowSize(newSize)
							self.lastTextContent = pendingText
						}
					}
				} else {
					if self.isVisible {
						self.orderOut(nil)
						// The reveal fades in from 0; restore it so the next appearance
						// is never left invisible.
						self.alphaValue = 1
						self.lastTextContent = ""
					}
				}
			}
		}
	}

	/// The HUD is showing the recipe error rather than live transcription. Matches
	/// DictationView, which gives `overlayError` priority over every other branch.
	private var isShowingRecipeError: Bool {
		coordinator.overlayError != nil
	}

	/// Repositions above the pill whenever the pill itself moves (a drag) or
	/// changes size, so this window never has to reach into `ListeningWindow`
	/// directly. See `PillAnchorProvider`.
	private func observePillMovement() {
		withObservationTracking {
			_ = PillAnchorProvider.shared.pillFrame
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				if self.isVisible {
					self.updateWindowSize(self.calculateDynamicSize())
				}
				self.observePillMovement()
			}
		}
	}

	private func calculateDynamicSize() -> NSSize {
		// The recipe error gets its own comfortable width.
		if let overlayError = coordinator.overlayError {
			let width = min(480, max(200, CGFloat(overlayError.count) * 7 + 60))
			return NSSize(width: width, height: 44)
		}

		let pendingText =
			live.isWaitingForModel
			? live.waitingForModelStatusText
			: live.stableDisplayText

		if pendingText.isEmpty {
			return NSSize(width: 120, height: 36)
		}

		let screenWidth = currentScreen().visibleFrame.width
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

	/// The screen the pill is resting on, so this window's width clamp and its
	/// anchor fallback agree with whatever display the pill is actually on.
	private func currentScreen() -> NSScreen {
		if let pillFrame = PillAnchorProvider.shared.pillFrame {
			for screen in NSScreen.screens where screen.frame.contains(NSPoint(x: pillFrame.midX, y: pillFrame.midY)) {
				return screen
			}
		}
		return NSScreen.main ?? NSScreen.screens.first!
	}

	/// First appearance: rises into place from just below its resting spot,
	/// the same reveal language `ListeningWindow` uses for its controls panel.
	private func presentAbovePill(size: NSSize) {
		let target = PillAnchor.frame(
			for: size, screenFrame: currentScreen().visibleFrame, pillFrame: PillAnchorProvider.shared.pillFrame)

		guard !Motion.systemReduceMotion else {
			alphaValue = 1
			setFrame(target, display: true)
			orderFront(nil)
			return
		}

		alphaValue = 0
		setFrame(target.offsetBy(dx: 0, dy: -Self.riseDistance), display: false)
		orderFront(nil)

		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			self.animator().setFrame(target, display: true)
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.revealDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			self.animator().alphaValue = 1
		}
	}

	/// How far below its resting place the reveal starts its rise.
	private static let riseDistance: CGFloat = 24

	private func updateWindowSize(_ newSize: NSSize) {
		let currentFrame = self.frame

		let widthDiff = abs(newSize.width - currentFrame.width)
		let heightDiff = abs(newSize.height - currentFrame.height)
		let pillFrame = PillAnchorProvider.shared.pillFrame
		let target = PillAnchor.frame(for: newSize, screenFrame: currentScreen().visibleFrame, pillFrame: pillFrame)

		// A pill move always repositions, even when the content size did not
		// change; a content-only change below the noise floor is skipped.
		guard widthDiff >= 10 || heightDiff >= 5 || abs(target.origin.x - currentFrame.origin.x) > 1
			|| abs(target.origin.y - currentFrame.origin.y) > 1
		else { return }

		guard !Motion.systemReduceMotion else {
			setFrame(target, display: true)
			return
		}

		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			self.animator().setFrame(target, display: true)
		}
	}
}
