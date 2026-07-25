import AppKit

private let logger = AppLogger.shared.ui

/// Carries the dictation result from the listening window into the text field it
/// is being pasted into: the listening window drops away and the particle field
/// flies from where it stood into the caret, dissolving as the paste lands.
///
/// One-way, unlike the onboarding route — there is nothing to come back to.
@MainActor
final class DictationMagnetController {
	/// The caret is a hairline; widen it a little so the field gathers into a
	/// blob rather than a one-pixel column.
	private static let targetPadding: CGFloat = 7

	private weak var sourceWindow: NSWindow?
	private var panel: NSPanel?
	private var renderer: EdgeMagnetRenderer?
	private var observer: NSObjectProtocol?

	init() {
		observer = NotificationCenter.default.addObserver(
			forName: .dictationWillPaste, object: nil, queue: .main
		) { [weak self] notification in
			let caret = (notification.object as? NSValue)?.rectValue
			MainActor.assumeIsolated { self?.run(caretAt: caret) }
		}
	}

	deinit {
		if let observer {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	/// The listening window the field flies out of.
	func attach(sourceWindow: NSWindow) {
		self.sourceWindow = sourceWindow
	}

	private func run(caretAt caret: CGRect?) {
		// no caret means the focused element never exposed one — flying the field
		// to a guessed location would be worse than not playing it at all
		guard MagnetField.dictationRouteEnabled(caret: caret), let caret else {
			logger.debug("EdgeMagnet: dictation transition not applicable")
			return
		}
		guard let source = sourceWindow else { return }
		guard panel == nil else { return }

		let targetRect = caret.insetBy(dx: -Self.targetPadding, dy: -Self.targetPadding)
		// the caret can be on a different display than the listening window;
		// the field has to be drawn on the one it is flying to
		let screen =
			NSScreen.screens.first { $0.frame.intersects(caret) } ?? source.screen ?? NSScreen.main
		guard let screen else { return }

		guard
			let built = MagnetField.make(
				on: screen,
				sourceRect: MagnetField.localRect(source.frame, on: screen),
				route: .rect(MagnetField.localRect(targetRect, on: screen)),
				profile: .dictation)
		else { return }

		built.renderer.onCompleted = { [weak self] in self?.teardown() }
		panel = built.panel
		renderer = built.renderer
		logger.debug("EdgeMagnet: dictation flight to \(targetRect.debugDescription)")
	}

	private func teardown() {
		renderer?.invalidate()
		panel?.orderOut(nil)
		panel = nil
		renderer = nil
	}
}
