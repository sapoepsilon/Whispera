import AppKit

private let logger = AppLogger.shared.ui

extension Notification.Name {
	/// Object is a `Bool`: true while the onboarding content should read as
	/// being pulled apart, false once it should settle back.
	static let onboardingMagnetDissolve = Notification.Name("OnboardingMagnetDissolve")
}

/// Onboarding-only flourish: when the Try It step starts recording, the window
/// dissolves into a particle field that flies out and pins itself to the screen
/// border, where the recording glow takes over. When the mic closes the field
/// converges back to the window rect and the window returns under it.
@MainActor
final class OnboardingMagnetController {

	private weak var window: NSWindow?
	private var panel: NSPanel?
	private var renderer: EdgeMagnetRenderer?
	private var isRunning = false

	/// Set by `OnboardingView` so the effect only fires from the Try It step.
	var isArmed = false {
		didSet {
			guard oldValue != isArmed, !isArmed else { return }
			cancel()
		}
	}

	func attach(to window: NSWindow) {
		self.window = window
	}

	func detach() {
		cancel()
		isArmed = false
		window = nil
	}

	func handle(state: AudioState) {
		switch state {
		case .initializing, .recording:
			start()
		case .transcribing, .idle:
			// the field comes home as soon as the mic closes; transcription
			// then runs with the window already back, and the ambient glow
			// tears down on the same state change so the two leave together
			beginReturn()
		}
	}

	// MARK: - Outbound

	private func start() {
		guard isArmed, !isRunning else { return }
		guard let window, window.isVisible else { return }
		guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
		guard let screen = window.screen ?? NSScreen.main else { return }
		// window frame is global; the panel spans one screen, so rebase onto it
		guard
			let built = MagnetField.make(
				on: screen,
				sourceRect: MagnetField.localRect(window.frame, on: screen),
				route: .screenBorder,
				profile: .onboarding)
		else { return }

		built.renderer.onSourceShouldVanish = { [weak self] in self?.hideWindow() }
		built.renderer.onSourceShouldReturn = { [weak self] in self?.showWindow() }
		built.renderer.onCompleted = { [weak self] in self?.finish() }

		self.panel = built.panel
		self.renderer = built.renderer
		isRunning = true
		logger.debug("EdgeMagnet: outbound started over \(screen.frame.debugDescription)")
	}

	private func hideWindow() {
		NotificationCenter.default.post(name: .onboardingMagnetDissolve, object: true)
		guard let window else { return }
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			context.timingFunction = CAMediaTimingFunction(name: .easeIn)
			window.animator().alphaValue = 0
		} completionHandler: { [weak window] in
			// alpha-zero windows still take clicks; get it out of the way
			window?.orderOut(nil)
		}
	}

	// MARK: - Inbound

	private func beginReturn() {
		guard isRunning, let renderer, !renderer.isReturning else { return }
		renderer.reverse()
	}

	private func showWindow() {
		NotificationCenter.default.post(name: .onboardingMagnetDissolve, object: false)
		guard let window else { return }
		window.alphaValue = 0
		window.makeKeyAndOrderFront(nil)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.24
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			window.animator().alphaValue = 1
		}
	}

	private func finish() {
		teardown()
		logger.debug("EdgeMagnet: transition complete")
	}

	// MARK: - Teardown

	func cancel() {
		guard isRunning else { return }
		showWindow()
		teardown()
	}

	private func teardown() {
		renderer?.invalidate()
		panel?.orderOut(nil)
		panel = nil
		renderer = nil
		isRunning = false
	}
}
