import Foundation

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

	init(mode: ActivationMode, holdThreshold: TimeInterval) {
		self.mode = mode
		self.holdThreshold = holdThreshold
	}

	mutating func keyDown(at time: Date, isRepeat: Bool, isSessionActive: Bool) -> ActivationAction {
		guard !isRepeat, !isPressed else { return .none }
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
