import AppKit
import SwiftUI

private let logger = AppLogger.shared.ui

class RecordingIndicatorWindow: NSWindow {
	init() {
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)

		self.level = .floating
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = false
		self.isMovable = false
		self.ignoresMouseEvents = true
		self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

		let hostingView = NSHostingView(rootView: RecordingIndicatorView())
		self.contentView = hostingView
	}

	func show(position: RecordingOverlayPosition) {
		guard let screen = NSScreen.main else {
			logger.debug("No main screen; not showing the minimal recording indicator")
			return
		}
		let origin = RecordingOverlayPolicy.origin(
			for: frame.size, in: screen.visibleFrame, position: position)
		setFrameOrigin(origin)
		orderFront(nil)

		alphaValue = 0
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
	@State private var pulseAnimation: Bool = false
	@State private var waveScale: CGFloat = 1.0

	var body: some View {
		ZStack {
			// Outer pulse ring
			Circle()
				.stroke(.red.opacity(0.3), lineWidth: 2)
				.frame(width: 40, height: 40)
				.scaleEffect(waveScale)
				.opacity(0.8)

			// Background circle
			Circle()
				.fill(.red.opacity(0.8))
				.frame(width: 32, height: 32)
				.scaleEffect(pulseAnimation ? 1.05 : 1.0)

			// Main microphone icon with sound waves
			HStack(spacing: 2) {
				// Sound wave lines
				VStack(spacing: 2) {
					Rectangle()
						.fill(.white)
						.frame(width: 2, height: pulseAnimation ? 8 : 4)
					Rectangle()
						.fill(.white)
						.frame(width: 2, height: pulseAnimation ? 12 : 6)
					Rectangle()
						.fill(.white)
						.frame(width: 2, height: pulseAnimation ? 6 : 3)
				}
				.opacity(0.8)

				// Microphone icon
				Image(systemName: "mic.fill")
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.white)
			}
		}
		.frame(width: 60, height: 60)
		.onAppear {
			startListeningAnimation()
		}
	}

	private func startListeningAnimation() {
		// Gentle pulse animation
		withAnimation(
			.easeInOut(duration: 1.2)
				.repeatForever(autoreverses: true)
		) {
			pulseAnimation = true
		}

		// Subtle wave pulse
		withAnimation(
			.easeInOut(duration: 1.8)
				.repeatForever(autoreverses: true)
		) {
			waveScale = 1.3
		}
	}
}

@MainActor
class RecordingIndicatorManager: ObservableObject {
	private var indicatorWindow: RecordingIndicatorWindow?

	func showIndicator(position: RecordingOverlayPosition) {
		hideIndicator()
		indicatorWindow = RecordingIndicatorWindow()
		indicatorWindow?.show(position: position)
	}

	func hideIndicator() {
		indicatorWindow?.hide()
		indicatorWindow = nil
	}
}
