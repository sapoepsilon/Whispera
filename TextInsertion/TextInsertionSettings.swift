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

enum AutoSubmitKey: String, CaseIterable, Identifiable, Sendable {
	case returnKey
	case controlReturn
	case commandReturn

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .returnKey: return "Return"
		case .controlReturn: return "Control-Return"
		case .commandReturn: return "Command-Return"
		}
	}

	var flags: CGEventFlags {
		switch self {
		case .returnKey: return []
		case .controlReturn: return .maskControl
		case .commandReturn: return .maskCommand
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
		static let autoSubmit = "autoSubmit"
		static let autoSubmitKey = "autoSubmitKey"
		static let appendTrailingSpace = "appendTrailingSpace"
	}

	static let defaultPasteDelayMs = 60
	static let delayRange: ClosedRange<Int> = 0...1000

	var clipboardHandling: ClipboardHandling = .restore
	var pasteDelayBeforeMs: Int = defaultPasteDelayMs
	var pasteDelayAfterMs: Int = defaultPasteDelayMs
	var pasteMethod: PasteMethod = .commandV
	var externalScriptPath = ""
	var autoSubmit = false
	var autoSubmitKey: AutoSubmitKey = .returnKey
	var appendTrailingSpace = false

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
		autoSubmit = defaults.bool(forKey: Keys.autoSubmit)
		if let raw = defaults.string(forKey: Keys.autoSubmitKey),
			let value = AutoSubmitKey(rawValue: raw)
		{
			autoSubmitKey = value
		}
		appendTrailingSpace = defaults.bool(forKey: Keys.appendTrailingSpace)
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
		defaults.set(autoSubmit, forKey: Keys.autoSubmit)
		defaults.set(autoSubmitKey.rawValue, forKey: Keys.autoSubmitKey)
		defaults.set(appendTrailingSpace, forKey: Keys.appendTrailingSpace)
	}

	// Live dictation already separates segments with a leading space
	func preparedText(_ text: String, for context: InsertionContext) -> String {
		guard appendTrailingSpace, context == .finalTranscript,
			let last = text.last, !last.isWhitespace
		else { return text }
		return text + " "
	}

	// Live segments arrive mid-sentence, so submitting after each one would send half a message
	func shouldAutoSubmit(for context: InsertionContext) -> Bool {
		autoSubmit && context == .finalTranscript && effectiveMethod(for: context) != .copyOnly
	}

	// Live segments always insert (see effectiveMethod), so only the toggle matters
	var shouldAutoSubmitAfterLiveSession: Bool {
		autoSubmit
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
