import Foundation

/// Where a shortcut press was observed. One physical press can reach the app through more
/// than one source around a secure input transition, but never twice through the same one.
enum ShortcutSource: Equatable, Sendable {
	case eventMonitor
	case systemHotKey
	case secureInputFallback
}

enum ActivationAction: Equatable {
	case start
	case stop
	case none
}

/// Turns raw shortcut press/release events into start/stop decisions for the
/// configured activation mode. `isSessionActive` must be true while a recording
/// is starting up or running, so a release during microphone startup still stops it.
struct ActivationStateMachine {
	var mode: ActivationMode
	var holdThreshold: TimeInterval

	private(set) var isPressed = false
	private var pressStartedAt: Date?
	private var pressStartedSession = false
	private var lastPress: (time: Date, source: ShortcutSource)?

	init(mode: ActivationMode, holdThreshold: TimeInterval) {
		self.mode = mode
		self.holdThreshold = holdThreshold
	}

	/// Two hotkey sources (the Carbon fallback and the event monitors) can report the
	/// same press around a secure input transition. Only a press from a different source is
	/// treated as a duplicate, so a genuine quick second press still stops the recording.
	static let duplicatePressWindow: TimeInterval = 0.3

	mutating func keyDown(
		at time: Date, isRepeat: Bool, isSessionActive: Bool, source: ShortcutSource = .eventMonitor
	) -> ActivationAction {
		guard !isRepeat else { return .none }
		if let last = lastPress, last.source != source,
			time.timeIntervalSince(last.time) < Self.duplicatePressWindow
		{
			return .none
		}
		lastPress = (time, source)
		if isPressed {
			// A fresh press while still "pressed" means the previous release was never
			// delivered (secure input, a re-registered hotkey); treat it as a new press
			// rather than ignoring the shortcut until relaunch.
			reset()
		}
		// Toggle mode is driven without a system-wide key-release monitor, so a press must not
		// latch waiting for a release that may never be delivered.
		isPressed = mode.needsKeyRelease
		pressStartedAt = time

		if isSessionActive {
			pressStartedSession = false
			return .stop
		}
		pressStartedSession = true
		return .start
	}

	mutating func keyUp(at time: Date, isSessionActive: Bool) -> ActivationAction {
		guard isPressed else { return .none }
		let startedAt = pressStartedAt ?? time
		let startedSession = pressStartedSession
		isPressed = false
		pressStartedAt = nil
		pressStartedSession = false

		guard startedSession, isSessionActive else { return .none }

		switch mode {
		case .toggle:
			return .none
		case .pushToTalk:
			return .stop
		case .holdOrToggle:
			return time.timeIntervalSince(startedAt) >= holdThreshold ? .stop : .none
		}
	}

	mutating func reset() {
		isPressed = false
		pressStartedAt = nil
		pressStartedSession = false
	}
}
