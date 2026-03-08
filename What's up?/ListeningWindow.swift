import AppKit
import SwiftUI

@MainActor
class ListeningWindow: NSWindow {
	private let audioManager: AudioManager
	private var observationTimer: Timer?
	private var frameObserver: Timer?
	private var stateObserver: NSObjectProtocol?
	private var pickerWindow: NSWindow?
	private var pickerToggleObserver: NSObjectProtocol?
	private var pickerDismissObserver: NSObjectProtocol?
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
		setupFrameObserver()
		setupPickerObservers()
	}

	deinit {
		observationTimer?.invalidate()
		frameObserver?.invalidate()
		if let observer = stateObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = pickerToggleObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = pickerDismissObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	private func updateVisibility() {
		let state = audioManager.currentState
		let shouldShow = state == .initializing
			|| (state != .idle && !enableStreaming)

		if shouldShow && !isVisible {
			positionAtBottomCenter()
			orderFront(nil)
		} else if !shouldShow && isVisible {
			hidePickerWindow()
			orderOut(nil)
		}
	}

	private func setupObservation() {
		stateObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateVisibility()
			}
		}

		observationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			Task { @MainActor in
				self?.updateVisibility()
			}
		}
	}

	private func setupFrameObserver() {
		frameObserver = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self, self.isVisible,
					let hostingView = self.contentView
				else { return }

				let fitting = hostingView.fittingSize
				let currentFrame = self.frame

				guard abs(fitting.height - currentFrame.height) > 1
					|| abs(fitting.width - currentFrame.width) > 1
				else { return }

				let newOriginY = currentFrame.origin.y + (currentFrame.height - fitting.height)
				let newOriginX = currentFrame.origin.x + (currentFrame.width - fitting.width) / 2
				let newFrame = NSRect(
					x: newOriginX,
					y: newOriginY,
					width: fitting.width,
					height: fitting.height
				)
				self.setFrame(newFrame, display: true, animate: false)
				self.repositionPickerWindow()
			}
		}
	}

	// MARK: - Picker Window

	private func setupPickerObservers() {
		pickerToggleObserver = NotificationCenter.default.addObserver(
			forName: .devicePickerToggled,
			object: nil,
			queue: .main
		) { [weak self] notification in
			Task { @MainActor in
				let show = (notification.userInfo?["show"] as? Bool) ?? false
				if show {
					self?.showPickerWindow()
				} else {
					self?.hidePickerWindow()
				}
			}
		}

		pickerDismissObserver = NotificationCenter.default.addObserver(
			forName: .devicePickerDismissed,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.hidePickerWindow()
			}
		}
	}

	private func showPickerWindow() {
		if pickerWindow == nil {
			let window = NSWindow(
				contentRect: .zero,
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.level = .floating
			window.isOpaque = false
			window.backgroundColor = .clear
			window.hasShadow = false

			let hostingView = NSHostingView(rootView: DevicePickerView(audioManager: audioManager))
			window.contentView = hostingView
			pickerWindow = window
		}

		repositionPickerWindow()
		pickerWindow?.orderFront(nil)
	}

	private func hidePickerWindow() {
		guard pickerWindow?.isVisible == true else { return }
		pickerWindow?.orderOut(nil)
		NotificationCenter.default.post(name: .devicePickerDismissed, object: self)
	}

	private func repositionPickerWindow() {
		guard let picker = pickerWindow, let pickerContent = picker.contentView else { return }

		let fittingSize = pickerContent.fittingSize
		let listeningFrame = self.frame

		let pickerX = listeningFrame.midX - fittingSize.width / 2
		let pickerY = listeningFrame.maxY + 8

		picker.setFrame(
			NSRect(x: pickerX, y: pickerY, width: fittingSize.width, height: fittingSize.height),
			display: true
		)
	}

	private func positionAtBottomCenter() {
		guard let screen = NSScreen.main else { return }
		let screenFrame = screen.visibleFrame
		let windowX = screenFrame.origin.x + (screenFrame.width - frame.width) / 2
		let windowY = screenFrame.origin.y + (screenFrame.height * 0.1)
		setFrameOrigin(NSPoint(x: windowX, y: windowY))
	}
}
