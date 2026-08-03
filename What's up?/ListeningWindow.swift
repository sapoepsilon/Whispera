import AppKit
import QuartzCore
import SwiftUI

/// Clamps for the listening pill and its controls panel. A measured size outside
/// these bounds is layout noise, not a real content change.
enum PillMetrics {
	static let minSize = CGSize(width: 80, height: 24)
	static let maxSize = CGSize(width: 720, height: 260)
	static let initialSize = CGSize(width: 230, height: 110)

	static let controlsMinSize = CGSize(width: 120, height: 24)
	static let controlsMaxSize = CGSize(width: 520, height: 640)
	static let controlsInitialSize = CGSize(width: 266, height: 120)

	/// Gap between the top of the pill and the bottom of the controls panel.
	static let controlsGap: CGFloat = 8
	/// Distance from the bottom of the screen, as a fraction of screen height.
	static let bottomAnchorFraction: CGFloat = 0.1
}

/// SwiftUI -> AppKit sizing bridge, the same shape as `PopoverPresenter`: the
/// content reports its natural laid-out size and the window assigns it once per
/// real change. Sub-point layout jitter is dropped so a measurement can never
/// re-trigger the AppKit resize that produced it.
@MainActor
@Observable
final class PillSizePresenter {
	private(set) var size: CGSize

	private let minSize: CGSize
	private let maxSize: CGSize

	init(initial: CGSize, minSize: CGSize, maxSize: CGSize) {
		self.size = initial
		self.minSize = minSize
		self.maxSize = maxSize
	}

	func setMeasured(_ measured: CGSize) {
		let clamped = CGSize(
			width: min(max(measured.width.rounded(), minSize.width), maxSize.width),
			height: min(max(measured.height.rounded(), minSize.height), maxSize.height)
		)
		if abs(clamped.width - size.width) > 1 || abs(clamped.height - size.height) > 1 {
			size = clamped
		}
	}
}

@MainActor
class ListeningWindow: NSWindow {
	private let audioManager: AudioManager
	private let pillPresenter = PillSizePresenter(
		initial: PillMetrics.initialSize,
		minSize: PillMetrics.minSize,
		maxSize: PillMetrics.maxSize
	)
	private let controlsPresenter = PillSizePresenter(
		initial: PillMetrics.controlsInitialSize,
		minSize: PillMetrics.controlsMinSize,
		maxSize: PillMetrics.controlsMaxSize
	)

	private var stateObserver: NSObjectProtocol?
	private var pickerToggleObserver: NSObjectProtocol?
	private var pickerDismissObserver: NSObjectProtocol?
	private var moveObserver: NSObjectProtocol?
	private var resizeObserver: NSObjectProtocol?
	private var pickerWindow: NSWindow?

	/// Non-zero while this class is driving an animated frame change on both
	/// windows, so the didMove/didResize follow-up does not fight the animation it
	/// caused. A counter, not a flag: back-to-back size changes overlap, and a
	/// flag would be cleared by the first one finishing.
	private var drivenFrameAnimations = 0
	private var isDrivingFrameAnimation: Bool { drivenFrameAnimations > 0 }

	/// Guards the panel's exit animation: `isDismissingPicker` stops a second
	/// dismissal stacking on top, and the generation token stops a stale exit
	/// completion from ordering out a panel that has since been reopened.
	private var isDismissingPicker = false
	private var pickerDismissalGeneration = 0

	@AppStorage("enableStreaming") private var enableStreaming = false

	init(audioManager: AudioManager) {
		self.audioManager = audioManager

		super.init(
			contentRect: NSRect(origin: .zero, size: PillMetrics.initialSize),
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

		let hostingView = NSHostingView(
			rootView: ListeningView(audioManager: audioManager, presenter: pillPresenter))
		self.contentView = hostingView

		setupVisibilityObservation()
		setupSizeObservation()
		setupPickerObservers()
		setupFollowObservers()

		// Observation only reports *changes*; without this the pill would miss a
		// recording that was already in flight when the window was constructed.
		updateVisibility()
	}

	deinit {
		for observer in [stateObserver, pickerToggleObserver, pickerDismissObserver, moveObserver, resizeObserver] {
			if let observer {
				NotificationCenter.default.removeObserver(observer)
			}
		}
	}

	// MARK: - Visibility

	private func updateVisibility() {
		let shouldShow = RecordingWindowPolicy.shouldShowListeningWindow(
			state: audioManager.currentState,
			mode: audioManager.currentRecordingMode
		)

		if shouldShow && !isVisible {
			// State often changes while the pill is hidden with no layout running;
			// re-measure and size before showing so it never opens stale and clipped.
			contentView?.layoutSubtreeIfNeeded()
			applyPillSize(animated: false)
			positionAtBottomCenter()
			orderFront(nil)
		} else if !shouldShow && isVisible {
			hidePickerWindow(animated: false)
			orderOut(nil)
		}
	}

	private func setupVisibilityObservation() {
		stateObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.updateVisibility()
			}
		}

		// RecordingStateChanged covers the three stored AudioManager flags but not
		// `currentRecordingMode`, which the policy also reads. Observing the
		// computed policy inputs directly closes that gap without polling.
		observeRecordingState()
	}

	private func observeRecordingState() {
		withObservationTracking {
			_ = audioManager.currentState
			_ = audioManager.currentRecordingMode
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.updateVisibility()
				self.observeRecordingState()
			}
		}
	}

	// MARK: - Sizing

	private func setupSizeObservation() {
		observePillSize()
		observeControlsSize()
	}

	private func observePillSize() {
		withObservationTracking {
			_ = pillPresenter.size
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.applyPillSize(animated: true)
				self.observePillSize()
			}
		}
	}

	private func observeControlsSize() {
		withObservationTracking {
			_ = controlsPresenter.size
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.layoutPickerWindow(size: self.controlsPresenter.size, animated: true)
				self.observeControlsSize()
			}
		}
	}

	private func applyPillSize(animated: Bool) {
		let target = pillPresenter.size
		let current = frame

		guard abs(target.width - current.width) > 1 || abs(target.height - current.height) > 1
		else { return }

		// The bottom edge is pinned: the pill rests a fixed distance up from the
		// bottom of the screen, so it has to grow upward or it walks off its anchor
		// (and off the drag position the user chose).
		let newFrame = NSRect(
			x: (current.midX - target.width / 2).rounded(),
			y: current.origin.y,
			width: target.width,
			height: target.height
		)

		guard animated, isVisible, !Motion.systemReduceMotion else {
			setFrame(newFrame, display: true)
			layoutPickerWindow(pillFrame: newFrame, animated: false)
			return
		}

		// The presenter's published size, never `picker.frame.size`: mid page
		// transition the live frame is an intermediate value, and folding that back
		// in would strand the panel at a partial height.
		let pickerTarget: NSRect? = pickerWindow.flatMap { picker in
			picker.isVisible ? pickerFrame(size: controlsPresenter.size, pillFrame: newFrame) : nil
		}

		drivenFrameAnimations += 1
		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			self.animator().setFrame(newFrame, display: true)
			if let pickerTarget, let picker = self.pickerWindow {
				picker.animator().setFrame(pickerTarget, display: true)
			}
		} completionHandler: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.drivenFrameAnimations = max(0, self.drivenFrameAnimations - 1)
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
					self.showPickerWindow(
						PillControlsView(audioManager: self.audioManager, presenter: self.controlsPresenter))
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

	/// Keeps the controls panel glued to the pill while the user drags it, and
	/// while any frame change this class did not initiate lands.
	private func setupFollowObservers() {
		moveObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification,
			object: self,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self, !self.isDrivingFrameAnimation else { return }
				self.layoutPickerWindow(animated: false)
			}
		}

		resizeObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didResizeNotification,
			object: self,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				guard let self, !self.isDrivingFrameAnimation else { return }
				self.layoutPickerWindow(animated: false)
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
		guard let picker = pickerWindow else { return }
		picker.contentView = NSHostingView(rootView: rootView)

		// One synchronous measurement at show time; every later size change arrives
		// through the presenter. Seeding the presenter here also makes it
		// authoritative from the first visible frame, so the fallbacks above never
		// read a size left over from a previous show.
		picker.contentView?.layoutSubtreeIfNeeded()
		let measured = picker.contentView?.fittingSize ?? .zero
		if measured.width > 1 && measured.height > 1 {
			controlsPresenter.setMeasured(measured)
		}

		// Any in-flight dismissal is now stale: bump the generation so its
		// completion handler cannot order this freshly shown window back out.
		pickerDismissalGeneration += 1
		isDismissingPicker = false

		let target = pickerFrame(size: controlsPresenter.size, pillFrame: frame)

		guard !Motion.systemReduceMotion else {
			picker.alphaValue = 1
			picker.setFrame(target, display: true)
			picker.orderFront(nil)
			return
		}

		// Open as a growth out of the pill: the panel is already at its final
		// layout, and the window frame expanding upward from the pill's top edge is
		// what reveals it. The frame is the clip.
		picker.alphaValue = 0
		picker.setFrame(collapsedPickerFrame(size: target.size, pillFrame: frame), display: false)
		picker.orderFront(nil)

		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			picker.animator().setFrame(target, display: true)
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.revealDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			picker.animator().alphaValue = 1
		}
	}

	/// The panel's closed state: a sliver sitting on the pill's top edge, so open
	/// and close read as the panel growing out of / collapsing back into the pill.
	private func collapsedPickerFrame(size: CGSize, pillFrame: NSRect) -> NSRect {
		NSRect(
			x: (pillFrame.midX - size.width / 2).rounded(),
			y: pillFrame.maxY + PillMetrics.controlsGap,
			width: size.width,
			height: 1
		)
	}

	/// The exact reverse of the open: the panel shrinks back down into the pill and
	/// fades, and only then is the window ordered out. `animated: false` is for the
	/// pill itself going away, where the whole surface should just disappear.
	private func hidePickerWindow(animated: Bool = true) {
		guard let picker = pickerWindow, picker.isVisible else { return }

		guard animated, !Motion.systemReduceMotion else {
			finishPickerDismissal()
			return
		}
		guard !isDismissingPicker else { return }

		isDismissingPicker = true
		pickerDismissalGeneration += 1
		let generation = pickerDismissalGeneration
		let collapsed = collapsedPickerFrame(size: controlsPresenter.size, pillFrame: frame)

		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.revealDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			picker.animator().alphaValue = 0
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			picker.animator().setFrame(collapsed, display: true)
		} completionHandler: {
			Task { @MainActor [weak self] in
				guard let self, self.pickerDismissalGeneration == generation else { return }
				self.finishPickerDismissal()
			}
		}
	}

	/// The single owner of the panel's `orderOut`, so a pill that hides mid-exit
	/// and the exit animation itself can never both try to tear it down.
	private func finishPickerDismissal() {
		isDismissingPicker = false
		pickerDismissalGeneration += 1
		guard let picker = pickerWindow, picker.isVisible else { return }
		picker.orderOut(nil)
		picker.alphaValue = 1
		NotificationCenter.default.post(name: .pillControlsDismissed, object: self)
	}

	private func pickerFrame(size: CGSize, pillFrame: NSRect) -> NSRect {
		NSRect(
			x: (pillFrame.midX - size.width / 2).rounded(),
			y: pillFrame.maxY + PillMetrics.controlsGap,
			width: size.width,
			height: size.height
		)
	}

	private func layoutPickerWindow(pillFrame: NSRect? = nil, size: CGSize? = nil, animated: Bool) {
		guard let picker = pickerWindow, picker.isVisible, !isDismissingPicker else { return }

		// Falls back to the presenter's published target, never the live frame: a
		// didMove/didResize landing mid page transition would otherwise read the
		// intermediate height and pin the panel to it.
		let resolvedSize = size ?? controlsPresenter.size
		guard resolvedSize.width > 1, resolvedSize.height > 1 else { return }

		let target = pickerFrame(size: resolvedSize, pillFrame: pillFrame ?? frame)
		let current = picker.frame
		guard abs(target.origin.x - current.origin.x) > 1
			|| abs(target.origin.y - current.origin.y) > 1
			|| abs(target.width - current.width) > 1
			|| abs(target.height - current.height) > 1
		else { return }

		guard animated, !Motion.systemReduceMotion else {
			picker.setFrame(target, display: true)
			return
		}

		NSAnimationContext.runAnimationGroup { context in
			context.duration = Motion.structuralDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			context.allowsImplicitAnimation = true
			picker.animator().setFrame(target, display: true)
		}
	}

	private func positionAtBottomCenter() {
		guard let screen = NSScreen.main else { return }
		let screenFrame = screen.visibleFrame
		let windowX = screenFrame.origin.x + (screenFrame.width - frame.width) / 2
		let windowY = screenFrame.origin.y + (screenFrame.height * PillMetrics.bottomAnchorFraction)
		setFrameOrigin(NSPoint(x: windowX, y: windowY))
	}
}
