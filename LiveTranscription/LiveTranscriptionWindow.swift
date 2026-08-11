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
	// Latched once the session shows its first words, cleared when the window
	// leaves. It is what lets a momentarily blank transcript keep the window up
	// (DictationView holds the words themselves) without ever allowing a window
	// that has shown nothing yet — the wide empty capsule the WHI-58 QA session
	// caught mid-dictation.
	private var hadWordsThisSession = false
	// The frame's grow-fast/shrink-slow state; see DictationHUDFrame.
	private var frameRule = DictationHUDFrame()

	@AppStorage("liveTranscriptionMaxWidthPercentage") private var maxWidthPercentage = 0.6
	// The width estimate must price the words DictationView actually shows —
	// its trailing ticker caps at this many — not the whole transcript, or the
	// frame would race to the ceiling while the visible text stays short.
	@AppStorage("liveTranscriptionMaxWords") private var maxWordsToShow = 5

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
				if self.isSessionActive, !self.live.isWaitingForModel,
					!self.live.stableDisplayText.isEmpty
				{
					self.hadWordsThisSession = true
				}
				// The window shows only while it has something to say — a status
				// line, words, or words it is holding through a momentarily blank
				// transcript (the mid-sentence jumping the WHI-58 QA session
				// reported). A session that has said nothing yet keeps the window
				// hidden rather than presenting an empty capsule.
				let hasContent = DictationHUDContent.hasSomethingToSay(
					overlayError: self.coordinator.overlayError,
					isWaitingForModel: self.live.isWaitingForModel,
					waitingStatusText: self.live.waitingForModelStatusText,
					displayText: self.live.stableDisplayText,
					hasShownWordsThisSession: self.hadWordsThisSession)
				let shouldShow =
					RecordingWindowPolicy.shouldShowLiveTranscriptionWindow(
						mode: self.audioManager.currentRecordingMode,
						transcriberWantsWindow: self.isSessionActive
							&& self.live.shouldShowLiveTranscriptionWindow && hasContent
					) || recipeActive

				if shouldShow {
					let newSize = self.calculateDynamicSize()

					if !self.isVisible {
						// The first presentation waits for the pill's published frame
						// when the pill is on its way: presenting against the fallback
						// spot lands the capsule on the pill itself and then visibly
						// snaps up once the frame arrives — the detached-at-start the
						// WHI-58 QA session reported. The pill publishes as part of
						// its own show pass, so this waits at most one poll tick.
						let pillExpected = RecordingWindowPolicy.shouldShowListeningWindow(
							state: self.audioManager.currentState)
						if pillExpected && PillAnchorProvider.shared.pillFrame == nil { return }
						self.presentAbovePill(size: newSize)
					} else {
						let pendingText =
							self.live.isWaitingForModel
							? self.live.waitingForModelStatusText
							: self.live.stableDisplayText

						// Changed text resizes, but so does an unchanged one whose
						// frame rule has decayed: the shrink half of the hysteresis
						// fires on time, not on new words, so a speaker who pauses
						// still gets the gap closed under them.
						if pendingText != self.lastTextContent || self.isShowingRecipeError
							|| abs(newSize.width - self.frame.width) >= 1
						{
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
					self.hadWordsThisSession = false
				}
			}
		}
	}

	/// The HUD is showing the recipe error rather than live transcription. Matches
	/// DictationView, which gives `overlayError` priority over every other branch.
	private var isShowingRecipeError: Bool {
		coordinator.overlayError != nil
	}

	/// A dictation is running: the engine is transcribing, or holding the
	/// session open behind a status line (waiting for model, reconnecting).
	private var isSessionActive: Bool {
		live.isTranscribing || live.isWaitingForModel
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

	/// The frame's calm-motion contract lives in `DictationHUDFrame`: while a
	/// dictation runs the width grows immediately on a coarse grid, decays one
	/// quantum at a time only after the text has stopped needing it for a
	/// sustained beat, and stops changing once it reaches the screen-derived
	/// ceiling. The content inside handles overflow (DictationView's trailing
	/// ticker). Hiding the window between sessions resets the growth to compact.
	private func calculateDynamicSize() -> NSSize {
		let maxWidth = min(currentScreen().visibleFrame.width * maxWidthPercentage, 800)
		// A hidden window has no width worth preserving; forgetting it here is
		// what starts the next session compact.
		if !isVisible { frameRule.reset() }
		let holdSteady = isSessionActive || isShowingRecipeError
		let now = CACurrentMediaTime()

		if let overlayError = coordinator.overlayError {
			// The recipe error is a caption-sized status line, measured like one.
			let width = frameRule.update(
				estimated: DictationHUDWidth.statusWidth(overlayError),
				maximum: maxWidth,
				isDictating: holdSteady,
				now: now
			)
			return NSSize(width: width, height: 44)
		}

		let estimated: CGFloat
		if live.isWaitingForModel {
			// A status line renders at caption size behind an indicator, not as
			// the word ticker; the shared rule still keeps its frame stable.
			estimated = DictationHUDWidth.statusWidth(live.waitingForModelStatusText)
		} else {
			let allWords = live.stableDisplayText.split(separator: " ")
			if allWords.isEmpty && hadWordsThisSession && isVisible {
				// The transcript blanked mid-session and DictationView is showing
				// its held words, which this window cannot measure. Hold the frame
				// as it is rather than letting an empty measurement arm the decay.
				return NSSize(width: frame.width, height: 36)
			}
			estimated = DictationHUDWidth.estimatedWidth(
				words: allWords.suffix(maxWordsToShow).map(String.init),
				hasEllipsis: allWords.count > maxWordsToShow
			)
		}

		let width = frameRule.update(
			estimated: estimated,
			maximum: maxWidth,
			isDictating: holdSteady,
			now: now
		)
		return NSSize(width: width, height: 36)
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
