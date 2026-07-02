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
	private var postActionToggleObserver: NSObjectProtocol?
	private var postActionDismissObserver: NSObjectProtocol?
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
		if let observer = postActionToggleObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		if let observer = postActionDismissObserver {
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
		frameObserver = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self = self, self.isVisible,
					let hostingView = self.contentView
				else { return }

				let fitting = hostingView.fittingSize
				let currentFrame = self.frame

				guard abs(fitting.height - currentFrame.height) > 1
					|| abs(fitting.width - currentFrame.width) > 1
				else { return }

				let newOriginX = currentFrame.midX - fitting.width / 2
				let newOriginY = currentFrame.origin.y + (currentFrame.height - fitting.height)
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
			forName: .pillControlsToggled,
			object: nil,
			queue: .main
		) { [weak self] notification in
			Task { @MainActor in
				guard let self else { return }
				let show = (notification.userInfo?["show"] as? Bool) ?? false
				if show {
					self.showPickerWindow(PillControlsView(audioManager: self.audioManager, onSize: { [weak self] size in
						self?.resizePickerWindow(to: size)
					}))
				} else {
					self.hidePickerWindow()
				}
			}
		}

		pickerDismissObserver = NotificationCenter.default.addObserver(
			forName: .pillControlsDismissed,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.hidePickerWindow()
			}
		}
	}

	private func showPickerWindow(_ rootView: some View) {
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
			pickerWindow = window
		}

		// (Re)host the requested picker each time so one floating panel serves both
		// the device picker and the post-action picker (WHI-50).
		pickerWindow?.contentView = NSHostingView(rootView: rootView)
		repositionPickerWindow()
		pickerWindow?.orderFront(nil)
	}

	private func hidePickerWindow() {
		guard pickerWindow?.isVisible == true else { return }
		pickerWindow?.orderOut(nil)
		NotificationCenter.default.post(name: .pillControlsDismissed, object: self)
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

	/// Follows the picker's live (animating) SwiftUI size so the window grows/
	/// shrinks smoothly during page transitions instead of snapping. WHI-50.
	private func resizePickerWindow(to size: CGSize) {
		guard let picker = pickerWindow, size.width > 1, size.height > 1 else { return }
		let x = self.frame.midX - size.width / 2
		let y = self.frame.maxY + 8
		picker.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
	}

	private func positionAtBottomCenter() {
		guard let screen = NSScreen.main else { return }
		let screenFrame = screen.visibleFrame
		let windowX = screenFrame.origin.x + (screenFrame.width - frame.width) / 2
		let windowY = screenFrame.origin.y + (screenFrame.height * 0.1)
		setFrameOrigin(NSPoint(x: windowX, y: windowY))
	}
}
