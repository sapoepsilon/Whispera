import Foundation

enum ActivationMode: String, CaseIterable, Identifiable {
	case toggle
	case pushToTalk
	case holdOrToggle

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .toggle: return "Toggle"
		case .pushToTalk: return "Push to Talk"
		case .holdOrToggle: return "Hold or Toggle"
		}
	}

	var summary: String {
		switch self {
		case .toggle: return "Press once to start, press again to stop"
		case .pushToTalk: return "Record while the shortcut is held down"
		case .holdOrToggle:
			return "A short tap toggles recording; holding past the threshold records until release"
		}
	}
}

enum MicStreamPolicy: String, CaseIterable, Identifiable {
	case onDemand
	case lazyClose
	case alwaysOn

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .onDemand: return "Open per recording"
		case .lazyClose: return "Keep open briefly"
		case .alwaysOn: return "Always on"
		}
	}

	var summary: String {
		switch self {
		case .onDemand: return "The microphone opens when you start and closes when you stop"
		case .lazyClose:
			return
				"The microphone stays open for a few seconds after stopping so a quick follow-up starts instantly"
		case .alwaysOn:
			return
				"The microphone stays open while Whispera runs for the fastest start; the mic indicator stays on"
		}
	}
}

enum ModelUnloadTimeout: String, CaseIterable, Identifiable {
	case never
	case immediately
	case seconds15
	case minutes1
	case minutes5
	case minutes15
	case hour1

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .never: return "Never"
		case .immediately: return "Immediately"
		case .seconds15: return "After 15 seconds"
		case .minutes1: return "After 1 minute"
		case .minutes5: return "After 5 minutes"
		case .minutes15: return "After 15 minutes"
		case .hour1: return "After 1 hour"
		}
	}

	/// `nil` means the model is never unloaded automatically.
	var interval: TimeInterval? {
		switch self {
		case .never: return nil
		case .immediately: return 0
		case .seconds15: return 15
		case .minutes1: return 60
		case .minutes5: return 300
		case .minutes15: return 900
		case .hour1: return 3600
		}
	}
}

struct RecordingControlSettings {
	enum Key {
		static let activationMode = "activationMode"
		static let holdThresholdMs = "holdThresholdMs"
		static let cancelShortcutEnabled = "cancelShortcutEnabled"
		static let extraRecordingBufferMs = "extraRecordingBufferMs"
		static let micStreamPolicy = "micStreamPolicy"
		static let lazyStreamCloseSeconds = "lazyStreamCloseSeconds"
		static let modelUnloadTimeout = "modelUnloadTimeout"
	}

	static let defaultHoldThresholdMs = 300
	static let holdThresholdRange = 100...1000
	static let extraRecordingBufferRange = 0...500
	static let defaultLazyStreamCloseSeconds = 10
	static let lazyStreamCloseOptions = [3, 5, 10, 30, 60]

	let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var activationMode: ActivationMode {
		defaults.string(forKey: Key.activationMode).flatMap(ActivationMode.init(rawValue:)) ?? .toggle
	}

	var holdThreshold: TimeInterval {
		let stored = defaults.object(forKey: Key.holdThresholdMs) as? Int ?? Self.defaultHoldThresholdMs
		return TimeInterval(stored.clamped(to: Self.holdThresholdRange)) / 1000
	}

	var cancelShortcutEnabled: Bool {
		defaults.object(forKey: Key.cancelShortcutEnabled) as? Bool ?? true
	}

	var extraRecordingBuffer: TimeInterval {
		let stored = defaults.object(forKey: Key.extraRecordingBufferMs) as? Int ?? 0
		return TimeInterval(stored.clamped(to: Self.extraRecordingBufferRange)) / 1000
	}

	var micStreamPolicy: MicStreamPolicy {
		defaults.string(forKey: Key.micStreamPolicy).flatMap(MicStreamPolicy.init(rawValue:))
			?? .onDemand
	}

	var lazyStreamCloseDelay: TimeInterval {
		let stored =
			defaults.object(forKey: Key.lazyStreamCloseSeconds) as? Int
			?? Self.defaultLazyStreamCloseSeconds
		return TimeInterval(stored.clamped(to: 1...300))
	}

	var modelUnloadTimeout: ModelUnloadTimeout {
		defaults.string(forKey: Key.modelUnloadTimeout).flatMap(ModelUnloadTimeout.init(rawValue:))
			?? .never
	}
}

extension Comparable {
	fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
