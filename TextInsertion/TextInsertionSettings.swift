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
		static let pasteDelayBeforeMs = "pasteDelayBeforeMs"
		static let pasteDelayAfterMs = "pasteDelayAfterMs"
	}

	static let defaultPasteDelayMs = 60
	static let delayRange: ClosedRange<Int> = 0...1000

	var clipboardHandling: ClipboardHandling = .restore
	var pasteDelayBeforeMs: Int = defaultPasteDelayMs
	var pasteDelayAfterMs: Int = defaultPasteDelayMs

	init() {}

	init(defaults: UserDefaults) {
		if let raw = defaults.string(forKey: Keys.clipboardHandling),
			let value = ClipboardHandling(rawValue: raw)
		{
			clipboardHandling = value
		}
		if defaults.object(forKey: Keys.pasteDelayBeforeMs) != nil {
			pasteDelayBeforeMs = Self.clampedDelay(defaults.integer(forKey: Keys.pasteDelayBeforeMs))
		}
		if defaults.object(forKey: Keys.pasteDelayAfterMs) != nil {
			pasteDelayAfterMs = Self.clampedDelay(defaults.integer(forKey: Keys.pasteDelayAfterMs))
		}
	}

	static var current: TextInsertionSettings {
		TextInsertionSettings(defaults: .standard)
	}

	func save(to defaults: UserDefaults) {
		defaults.set(clipboardHandling.rawValue, forKey: Keys.clipboardHandling)
		defaults.set(Self.clampedDelay(pasteDelayBeforeMs), forKey: Keys.pasteDelayBeforeMs)
		defaults.set(Self.clampedDelay(pasteDelayAfterMs), forKey: Keys.pasteDelayAfterMs)
	}

	static func clampedDelay(_ value: Int) -> Int {
		min(max(value, delayRange.lowerBound), delayRange.upperBound)
	}
}
