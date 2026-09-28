import AppKit

/// A stored shortcut such as "⌥⌘R" resolved to what the event monitors and Carbon compare.
struct ShortcutCombo: Equatable {
	static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

	let modifiers: NSEvent.ModifierFlags
	let keyCode: UInt16

	init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
		self.modifiers = modifiers.intersection(Self.relevantModifiers)
		self.keyCode = keyCode
	}

	/// Returns nil when the key part is empty or names a key we have no key code for, so an
	/// unreadable shortcut is never silently bound to some other key.
	init?(_ shortcut: String) {
		var modifiers: NSEvent.ModifierFlags = []
		if shortcut.contains("⌘") { modifiers.insert(.command) }
		if shortcut.contains("⌥") { modifiers.insert(.option) }
		if shortcut.contains("⌃") { modifiers.insert(.control) }
		if shortcut.contains("⇧") { modifiers.insert(.shift) }
		// Not trimmed here: a lone space is ⌥Space as the onboarding recorder stored it, and
		// keyCode(forKeyName:) already trims around longer names
		let key = Self.keyPart(of: shortcut)
		guard let keyCode = ShortcutKeyCodes.keyCode(forKeyName: key) else { return nil }
		self.init(modifiers: modifiers, keyCode: keyCode)
	}

	static let modifierSymbols = "⌘⌥⌃⇧"

	static func keyPart(of shortcut: String) -> String {
		shortcut.filter { !modifierSymbols.contains($0) }
	}
}

/// What an unset shortcut means. Every reader uses these so the menu, Settings, the cancel
/// recorder and the hotkey monitors never disagree about which key dictation listens on.
enum ShortcutDefaults {
	static let dictationKey = "globalShortcut"
	static let fileSelectionKey = "fileSelectionShortcut"
	static let dictation = "⌥⌘R"
	static let fileSelection = "⌃F"

	static func dictation(in defaults: UserDefaults) -> String {
		defaults.string(forKey: dictationKey) ?? dictation
	}

	static func fileSelection(in defaults: UserDefaults) -> String {
		defaults.string(forKey: fileSelectionKey) ?? fileSelection
	}
}

/// Turns a recorded key press into the stored symbol form. Shared by every dictation shortcut
/// recorder so what is saved always parses back to the key that was pressed.
enum DictationShortcutFormatter {
	/// F-keys and Globe type nothing, so they may be used without a modifier.
	static func allowsBareKey(_ keyCode: UInt16) -> Bool {
		keyCode == 63 || ShortcutKeyCodes.functionKeyCodes.contains(keyCode)
	}

	/// Nil when the key has no name or needs a modifier it does not have.
	static func format(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
		let flags = modifiers.intersection(ShortcutCombo.relevantModifiers)
		guard let key = ShortcutKeyCodes.keyName(forKeyCode: keyCode) else { return nil }
		guard !flags.isEmpty || allowsBareKey(keyCode) else { return nil }
		return PostProcessingShortcutFormatter.format(modifiers: flags, key: key)
	}
}

/// Older onboarding builds stored `charactersIgnoringModifiers`, which gives a bare space,
/// control characters and private-use F-key characters that no one can read.
enum ShortcutMigration {
	/// The stored shortcut rewritten with a readable key name, or nil when it needs no change.
	/// The modifier symbols are kept in their original order so ordinary values never churn.
	static func migrated(_ stored: String) -> String? {
		let key = ShortcutCombo.keyPart(of: stored)
		guard let name = ShortcutKeyCodes.legacyKeyName(for: key) else { return nil }
		let modifiers = stored.filter { ShortcutCombo.modifierSymbols.contains($0) }
		return modifiers + name
	}

	/// Rewrites legacy values in place. Returns the keys that changed.
	@discardableResult
	static func migrate(in defaults: UserDefaults) -> [String] {
		var changed: [String] = []
		for key in [ShortcutDefaults.dictationKey, ShortcutDefaults.fileSelectionKey] {
			guard let stored = defaults.string(forKey: key), let migrated = migrated(stored) else { continue }
			defaults.set(migrated, forKey: key)
			changed.append(key)
		}
		return changed
	}
}

/// Key names used in stored shortcuts, mapped to ANSI virtual key codes.
enum ShortcutKeyCodes {
	/// The first name listed for a key code is the one shortcut recorders write.
	private static let table: [(names: [String], keyCode: UInt16)] = [
		(["A"], 0), (["B"], 11), (["C"], 8), (["D"], 2), (["E"], 14), (["F"], 3), (["G"], 5),
		(["H"], 4), (["I"], 34), (["J"], 38), (["K"], 40), (["L"], 37), (["M"], 46), (["N"], 45),
		(["O"], 31), (["P"], 35), (["Q"], 12), (["R"], 15), (["S"], 1), (["T"], 17), (["U"], 32),
		(["V"], 9), (["W"], 13), (["X"], 7), (["Y"], 16), (["Z"], 6),
		// Shifted symbols are accepted because older recorders stored the shifted character
		(["0", ")"], 29), (["1", "!"], 18), (["2", "@"], 19), (["3", "#"], 20), (["4", "$"], 21),
		(["5", "%"], 23), (["6", "^"], 22), (["7", "&"], 26), (["8", "*"], 28), (["9", "("], 25),
		(["F1"], 122), (["F2"], 120), (["F3"], 99), (["F4"], 118), (["F5"], 96), (["F6"], 97),
		(["F7"], 98), (["F8"], 100), (["F9"], 101), (["F10"], 109), (["F11"], 103), (["F12"], 111),
		(["F13"], 105), (["F14"], 107), (["F15"], 113), (["F16"], 106), (["F17"], 64), (["F18"], 79),
		(["F19"], 80), (["F20"], 90),
		(["Space", " "], 49), (["Return", "Enter", "↩"], 36), (["Tab", "⇥"], 48),
		(["Delete", "⌫"], 51), (["Esc", "Escape", "⎋"], 53), (["Home", "↖"], 115), (["End", "↘"], 119),
		(["PageUp", "⇞"], 116), (["PageDown", "⇟"], 121), (["↑", "Up"], 126), (["↓", "Down"], 125),
		(["←", "Left"], 123), (["→", "Right"], 124), (["Clear", "⌧"], 71), (["Help"], 114),
		(["-", "_"], 27), (["=", "+"], 24), (["[", "{"], 33), (["]", "}"], 30), (["\\", "|"], 42),
		([";", ":"], 41), (["'", "\""], 39), ([",", "<"], 43), ([".", ">"], 47), (["/", "?"], 44),
		(["`", "~"], 50),
		(["Globe", "Fn", "🌐"], 63),
		(["Fwd Delete", "ForwardDelete", "⌦"], 117), (["KeypadEnter", "⌤"], 76),
	]

	static let functionKeyCodes: Set<UInt16> = [
		122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
	]

	/// Characters AppKit reports for non-printing keys, as older recorders stored them.
	private static let legacyCharacters: [Character: String] = {
		var map: [Character: String] = [
			" ": "Space", "\r": "Return", "\u{3}": "KeypadEnter", "\t": "Tab", "\u{19}": "Tab",
			"\u{1B}": "Esc", "\u{7F}": "Delete", "\u{8}": "Delete",
			"\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
			"\u{F728}": "Fwd Delete", "\u{F729}": "Home", "\u{F72B}": "End",
			"\u{F72C}": "PageUp", "\u{F72D}": "PageDown", "\u{F739}": "Clear", "\u{F746}": "Help",
		]
		// NSF1FunctionKey is U+F704 and the rest follow in order
		for index in 0..<20 {
			if let scalar = Unicode.Scalar(UInt32(0xF704 + index)) { map[Character(scalar)] = "F\(index + 1)" }
		}
		return map
	}()

	/// The readable name for a key part that an older recorder stored as a raw character.
	static func legacyKeyName(for key: String) -> String? {
		guard key.count == 1, let character = key.first else { return nil }
		return legacyCharacters[character]
	}

	private static let codesByName: [String: UInt16] = {
		var map: [String: UInt16] = [:]
		for entry in table {
			for name in entry.names { map[name.lowercased()] = entry.keyCode }
		}
		return map
	}()

	private static let namesByCode: [UInt16: String] = {
		var map: [UInt16: String] = [:]
		for entry in table where map[entry.keyCode] == nil { map[entry.keyCode] = entry.names[0] }
		return map
	}()

	static func keyCode(forKeyName name: String) -> UInt16? {
		guard !name.isEmpty else { return nil }
		// A lone space is a real key name, so only trim when something else is left
		if let legacy = legacyKeyName(for: name) {
			return codesByName[legacy.lowercased()]
		}
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		return codesByName[(trimmed.isEmpty ? name : trimmed).lowercased()]
	}

	/// Names the physical key, ignoring Shift and the keyboard layout, so ⌥⇧1 is recorded as
	/// "⌥⇧1" rather than "⌥⇧!" and F-keys get their name instead of a private-use character.
	static func keyName(forKeyCode keyCode: UInt16) -> String? {
		namesByCode[keyCode]
	}
}
