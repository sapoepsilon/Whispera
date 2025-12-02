//
//  ListeningWindow.swift
//  Whispera
//
//  Created by Varkhuman Mac on 10/18/25.
//

import AppKit
import SwiftUI

@MainActor
class ListeningWindow: NSWindow {
	private let audioManager: AudioManager
	private var observationTimer: Timer?
	@AppStorage("enableStreaming") private var enableStreaming = false

	init(audioManager: AudioManager) {
		self.audioManager = audioManager

		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 230, height: 110),
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

		let hostingView = NSHostingView(rootView: ListeningView(audioManager: audioManager))
		self.contentView = hostingView

		setupObservation()
	}

	deinit {
		observationTimer?.invalidate()
	}

	private func setupObservation() {
		observationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }

				let shouldShow =
					(self.audioManager.isRecording || self.audioManager.isTranscribing || self.audioManager.isMicrophoneInitializing)
					&& !self.enableStreaming

				if shouldShow && !self.isVisible {
					self.positionAtBottomCenter()
					self.orderFront(nil)
				} else if !shouldShow && self.isVisible {
					self.orderOut(nil)
				}
			}
		}
	}

	private func positionAtBottomCenter() {
		guard let screen = NSScreen.main else { return }
		let screenFrame = screen.visibleFrame
		let windowX = screenFrame.origin.x + (screenFrame.width - frame.width) / 2
		let windowY = screenFrame.origin.y + (screenFrame.height * 0.1)
		setFrameOrigin(NSPoint(x: windowX, y: windowY))
	}
}
