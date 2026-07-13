import AppKit
import SwiftUI

private let logger = AppLogger.shared.ui

struct RecordingGlowView: View {
	private let startDate = Date()

	var body: some View {
		// 30fps is indistinguishable for this slow ambient sweep and halves
		// the GPU frame count on ProMotion displays
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let time = Float(context.date.timeIntervalSince(startDate))
			Rectangle()
				.colorEffect(
					ShaderLibrary.recordingGlow(
						.boundingRect,
						.float(time),
						.float(0.8 + 0.2 * sin(time * 2.0))
					)
				)
		}
		.ignoresSafeArea()
	}
}

@MainActor
final class RecordingGlowController {
	private let audioManager: AudioManager
	private var glowPanel: NSPanel?
	private var screenObserver: NSObjectProtocol?

	init(audioManager: AudioManager) {
		self.audioManager = audioManager

		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, let panel = self.glowPanel, let screen = NSScreen.main else { return }
				panel.setFrame(screen.frame, display: true)
			}
		}
	}

	deinit {
		if let observer = screenObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	func updateVisibility() {
		let enabled = UserDefaults.standard.bool(forKey: "enableRecordingGlow")
		if enabled && audioManager.currentState == .recording {
			show()
		} else {
			hide()
		}
	}

	private func show() {
		guard glowPanel == nil else { return }
		guard let screen = NSScreen.main else {
			logger.error("No main screen available for recording glow")
			return
		}

		let panel = NSPanel(
			contentRect: screen.frame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.level = .screenSaver
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.hidesOnDeactivate = false
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
		panel.contentView = NSHostingView(rootView: RecordingGlowView())
		panel.orderFrontRegardless()

		glowPanel = panel
		logger.debug("Recording glow shown on screen \(screen.frame.debugDescription)")
	}

	private func hide() {
		guard let panel = glowPanel else { return }
		panel.orderOut(nil)
		// dropping the panel tears down the TimelineView render loop so
		// nothing animates while idle
		glowPanel = nil
		logger.debug("Recording glow hidden")
	}
}
