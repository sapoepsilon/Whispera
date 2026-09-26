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
		let key = shortcut.filter { !"⌘⌥⌃⇧".contains($0) }.trimmingCharacters(in: .whitespaces)
		guard let keyCode = ShortcutKeyCodes.keyCode(forKeyName: key) else { return nil }
		self.init(modifiers: modifiers, keyCode: keyCode)
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
	]

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
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		return codesByName[(trimmed.isEmpty ? name : trimmed).lowercased()]
	}

	/// Names the physical key, ignoring Shift and the keyboard layout, so ⌥⇧1 is recorded as
	/// "⌥⇧1" rather than "⌥⇧!" and F-keys get their name instead of a private-use character.
	static func keyName(forKeyCode keyCode: UInt16) -> String? {
		namesByCode[keyCode]
	}
}
