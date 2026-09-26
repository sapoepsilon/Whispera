import CoreGraphics
import Foundation

enum ClipboardHandling: String, CaseIterable, Identifiable, Sendable {
	case restore
	case keepTranscript

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .restore: return "Restore previous clipboard"
		case .keepTranscript: return "Keep transcript on clipboard"
		}
	}
}

enum InsertionContext: Sendable {
	case finalTranscript
	case liveSegment
}

struct TextInsertionSettings: Equatable, Sendable {
	enum Keys {
		static let clipboardHandling = "clipboardHandling"
	}

	static let pasteDelayMs = 60

	var clipboardHandling: ClipboardHandling = .restore
	var pasteDelayBeforeMs: Int = pasteDelayMs
	var pasteDelayAfterMs: Int = pasteDelayMs

	init() {}

	init(defaults: UserDefaults) {
		if let raw = defaults.string(forKey: Keys.clipboardHandling),
			let value = ClipboardHandling(rawValue: raw)
		{
			clipboardHandling = value
		}
	}

	static var current: TextInsertionSettings {
		TextInsertionSettings(defaults: .standard)
	}

	func save(to defaults: UserDefaults) {
		defaults.set(clipboardHandling.rawValue, forKey: Keys.clipboardHandling)
	}
}
