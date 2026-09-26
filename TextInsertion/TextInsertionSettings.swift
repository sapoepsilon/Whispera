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

enum PasteMethod: String, CaseIterable, Identifiable, Sendable {
	case commandV
	case typeCharacters
	case copyOnly
	case externalScript

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .commandV: return "Paste (Cmd-V)"
		case .typeCharacters: return "Type characters"
		case .copyOnly: return "Copy to clipboard only"
		case .externalScript: return "Run script"
		}
	}

	var summary: String {
		switch self {
		case .commandV: return "Puts the transcript on the clipboard and presses Cmd-V"
		case .typeCharacters: return "Types the text key by key, for apps that block pasting"
		case .copyOnly: return "Leaves the transcript on the clipboard without inserting it"
		case .externalScript: return "Runs your script with the transcript as its first argument"
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
		static let pasteMethod = "pasteMethod"
		static let externalScriptPath = "externalScriptPath"
	}

	static let defaultPasteDelayMs = 60
	static let delayRange: ClosedRange<Int> = 0...1000

	var clipboardHandling: ClipboardHandling = .restore
	var pasteDelayBeforeMs: Int = defaultPasteDelayMs
	var pasteDelayAfterMs: Int = defaultPasteDelayMs
	var pasteMethod: PasteMethod = .commandV
	var externalScriptPath = ""

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
		if let raw = defaults.string(forKey: Keys.pasteMethod), let value = PasteMethod(rawValue: raw) {
			pasteMethod = value
		}
		externalScriptPath = defaults.string(forKey: Keys.externalScriptPath) ?? ""
	}

	static var current: TextInsertionSettings {
		TextInsertionSettings(defaults: .standard)
	}

	func save(to defaults: UserDefaults) {
		defaults.set(clipboardHandling.rawValue, forKey: Keys.clipboardHandling)
		defaults.set(Self.clampedDelay(pasteDelayBeforeMs), forKey: Keys.pasteDelayBeforeMs)
		defaults.set(Self.clampedDelay(pasteDelayAfterMs), forKey: Keys.pasteDelayAfterMs)
		defaults.set(pasteMethod.rawValue, forKey: Keys.pasteMethod)
		defaults.set(externalScriptPath, forKey: Keys.externalScriptPath)
	}

	// Live dictation must land in the focused app as it streams, so non-inserting methods fall back to Cmd-V
	func effectiveMethod(for context: InsertionContext) -> PasteMethod {
		switch (context, pasteMethod) {
		case (.liveSegment, .copyOnly), (.liveSegment, .externalScript): return .commandV
		default: return pasteMethod
		}
	}

	static func clampedDelay(_ value: Int) -> Int {
		min(max(value, delayRange.lowerBound), delayRange.upperBound)
	}
}
