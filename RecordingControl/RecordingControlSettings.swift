import Foundation

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
		static let cancelShortcutEnabled = "cancelShortcutEnabled"
		static let modelUnloadTimeout = "modelUnloadTimeout"
	}

	let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var cancelShortcutEnabled: Bool {
		defaults.object(forKey: Key.cancelShortcutEnabled) as? Bool ?? true
	}

	var modelUnloadTimeout: ModelUnloadTimeout {
		defaults.string(forKey: Key.modelUnloadTimeout).flatMap(ModelUnloadTimeout.init(rawValue:))
			?? .never
	}
}
