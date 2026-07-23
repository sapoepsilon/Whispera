import AppKit
import SwiftUI

private let logger = AppLogger.shared.ui

enum RecordingGlowColor {
	static let key = "recordingGlowColor"
	static let defaultHex = "0A84FF"

	static func color(fromHex hex: String) -> Color {
		var value: UInt64 = 0
		let scanner = Scanner(string: hex)
		guard hex.count == 6, scanner.scanHexInt64(&value), scanner.isAtEnd else {
			return Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 1.0)
		}
		return Color(
			red: Double((value >> 16) & 0xFF) / 255.0,
			green: Double((value >> 8) & 0xFF) / 255.0,
			blue: Double(value & 0xFF) / 255.0
		)
	}

	static func hex(from color: Color) -> String {
		guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return defaultHex }
		return String(
			format: "%02X%02X%02X",
			Int(round(srgb.redComponent * 255)),
			Int(round(srgb.greenComponent * 255)),
			Int(round(srgb.blueComponent * 255))
		)
	}
}

// fast attack so the glow jumps with speech onset, slow release so it
// decays smoothly instead of flickering between words
private final class GlowLevelSmoother {
	private var value: Float = 0
	private var lastTime: Float?

	func step(toward target: Float, at time: Float) -> Float {
		let dt = lastTime.map { max(0, time - $0) } ?? 0
		lastTime = time
		let timeConstant: Float = target > value ? 0.03 : 0.2
		value += (target - value) * (1 - exp(-dt / timeConstant))
		return value
	}
}

struct RecordingGlowView: View {
	@AppStorage(RecordingGlowColor.key) private var glowColorHex = RecordingGlowColor.defaultHex
	let levelMonitor: AudioLevelMonitor
	private let startDate = Date()
	private let smoother = GlowLevelSmoother()

	var body: some View {
		// 30fps is indistinguishable for this slow ambient sweep and halves
		// the GPU frame count on ProMotion displays
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
			let time = Float(context.date.timeIntervalSince(startDate))
			let level = smoother.step(toward: levelMonitor.overallLevel, at: time)
			Rectangle()
				.colorEffect(
					ShaderLibrary.recordingGlow(
						.boundingRect,
						.color(RecordingGlowColor.color(fromHex: glowColorHex)),
						.float(time),
						.float(0.8 + 0.2 * sin(time * 2.0)),
						.float(level)
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
		panel.contentView = NSHostingView(
			rootView: RecordingGlowView(levelMonitor: audioManager.levelMonitor))
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
