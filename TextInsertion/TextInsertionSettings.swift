import CoreGraphics
import Foundation

enum ClipboardHandling: String, CaseIterable, Identifiable, Sendable {
	case restore
	case keepTranscript

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .restore: return String(localized: "Restore previous clipboard")
		case .keepTranscript: return String(localized: "Keep transcript on clipboard")
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
		case .commandV: return String(localized: "Paste (⌘V)")
		case .typeCharacters: return String(localized: "Type characters")
		case .copyOnly: return String(localized: "Copy to clipboard only")
		case .externalScript: return String(localized: "Run script")
		}
	}

	var summary: String {
		switch self {
		case .commandV: return String(localized: "Puts the transcript on the clipboard and presses ⌘V")
		case .typeCharacters: return String(localized: "Types the text key by key, for apps that block pasting")
		case .copyOnly: return String(localized: "Leaves the transcript on the clipboard without inserting it")
		case .externalScript: return String(localized: "Runs a script you choose and passes it the transcript on standard input")
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
		case .returnKey: return String(localized: "Return")
		case .controlReturn: return String(localized: "Control-Return")
		case .commandReturn: return String(localized: "Command-Return")
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
		static let clipboardRestoreHoldMs = "clipboardRestoreHoldMs"
		static let pasteMethod = "pasteMethod"
		static let externalScriptPath = "externalScriptPath"
		static let externalScriptApproval = "externalScriptApproval"
		static let autoSubmit = "autoSubmit"
		static let autoSubmitKey = "autoSubmitKey"
		static let appendTrailingSpace = "appendTrailingSpace"
	}

	static let defaultPasteDelayMs = 60
	/// Grace period after the target app reads the transcript, before the old clipboard returns.
	static let defaultPasteDelayAfterMs = 150
	static let delayRange: ClosedRange<Int> = 0...1000
	/// Clipboard watchers read the transcript within milliseconds of the write, before Cmd-V is
	/// even sent, so a read says nothing about the target app. Measured on a signed build: a
	/// 60 ms restore pasted the old clipboard in 1 of 6 runs, a 500 ms hold in 0 of 16.
	static let defaultClipboardRestoreHoldMs = 500
	static let restoreHoldRange: ClosedRange<Int> = 0...3000

	var clipboardHandling: ClipboardHandling = .restore
	var pasteDelayBeforeMs: Int = defaultPasteDelayMs
	var pasteDelayAfterMs: Int = defaultPasteDelayAfterMs
	/// Least time between Cmd-V and putting the previous clipboard back.
	var clipboardRestoreHoldMs: Int = defaultClipboardRestoreHoldMs
	var pasteMethod: PasteMethod = .commandV
	var externalScriptPath = ""
	/// Set only when the user picks the script in Settings; see `ScriptApproval`.
	var externalScriptApproval = ""
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
		if defaults.object(forKey: Keys.clipboardRestoreHoldMs) != nil {
			clipboardRestoreHoldMs = Self.clampedHold(defaults.integer(forKey: Keys.clipboardRestoreHoldMs))
		}
		if let raw = defaults.string(forKey: Keys.pasteMethod), let value = PasteMethod(rawValue: raw) {
			pasteMethod = value
		}
		externalScriptPath = defaults.string(forKey: Keys.externalScriptPath) ?? ""
		externalScriptApproval = defaults.string(forKey: Keys.externalScriptApproval) ?? ""
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
		defaults.set(Self.clampedHold(clipboardRestoreHoldMs), forKey: Keys.clipboardRestoreHoldMs)
		defaults.set(pasteMethod.rawValue, forKey: Keys.pasteMethod)
		defaults.set(externalScriptPath, forKey: Keys.externalScriptPath)
		defaults.set(externalScriptApproval, forKey: Keys.externalScriptApproval)
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

	static func clampedHold(_ value: Int) -> Int {
		min(max(value, restoreHoldRange.lowerBound), restoreHoldRange.upperBound)
	}
}
