import AppKit

enum CancelShortcut {
	static let escapeKeyCode: UInt16 = 53

	static func matches(
		keyCode: UInt16, modifiers: NSEvent.ModifierFlags, binding: CancelShortcutBinding = .escape
	) -> Bool {
		binding.matches(keyCode: keyCode, modifiers: modifiers)
	}
}

/// The key that discards a dictation. Stored as a key code plus modifiers so layouts and
/// symbol spelling never change what it matches; `display` is only for the settings UI.
struct CancelShortcutBinding: Equatable, Sendable {
	static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
	static let escape = CancelShortcutBinding(keyCode: CancelShortcut.escapeKeyCode, modifiers: [], display: "Esc")

	/// Keys that are safe to use without a modifier: they never produce text, so pressing
	/// them during dictation cannot be a typo that throws the recording away.
	static let bareKeyCodes: Set<UInt16> = [
		53,  // Escape
		122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1-F12
		105, 107, 113, 106, 64, 79, 80, 90,  // F13-F20
		51, 117,  // Delete, Forward Delete
		114, 115, 119, 116, 121,  // Help, Home, End, Page Up, Page Down
	]

	let keyCode: UInt16
	let modifiers: NSEvent.ModifierFlags
	let display: String

	init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String) {
		self.keyCode = keyCode
		self.modifiers = modifiers.intersection(Self.relevantModifiers)
		self.display = display
	}

	static func == (lhs: CancelShortcutBinding, rhs: CancelShortcutBinding) -> Bool {
		lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
	}

	func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
		keyCode == self.keyCode && modifiers.intersection(Self.relevantModifiers) == self.modifiers
	}

	enum Rejection: Equatable {
		case needsModifier
		case sameAsShortcut(String)
	}

	/// `taken` are the other Whispera shortcuts in their stored symbol form (e.g. "⌥⌘R").
	func rejection(taken: [String]) -> Rejection? {
		if modifiers.isEmpty && !Self.bareKeyCodes.contains(keyCode) {
			return .needsModifier
		}
		if let clash = taken.first(where: { $0.caseInsensitiveCompare(display) == .orderedSame }) {
			return .sameAsShortcut(clash)
		}
		return nil
	}

	static func keyName(keyCode: UInt16, characters: String?) -> String? {
		switch keyCode {
		case 53: return "Esc"
		case 49: return "Space"
		case 36: return "Return"
		case 48: return "Tab"
		case 51: return "Delete"
		case 117: return "Fwd Delete"
		case 114: return "Help"
		case 115: return "Home"
		case 119: return "End"
		case 116: return "Page Up"
		case 121: return "Page Down"
		case 123: return "←"
		case 124: return "→"
		case 125: return "↓"
		case 126: return "↑"
		default:
			if let index = functionKeyCodes.firstIndex(of: keyCode) { return "F\(index + 1)" }
			guard let characters = characters?.uppercased(), !characters.isEmpty,
				!characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
			else { return nil }
			return characters
		}
	}

	private static let functionKeyCodes: [UInt16] = [
		122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
	]

	init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
		guard let key = Self.keyName(keyCode: keyCode, characters: characters) else { return nil }
		let relevant = modifiers.intersection(Self.relevantModifiers)
		self.init(
			keyCode: keyCode, modifiers: relevant,
			display: PostProcessingShortcutFormatter.format(modifiers: relevant, key: key))
	}
}

extension RecordingControlSettings {
	enum CancelKey {
		static let keyCode = "cancelShortcutKeyCode"
		static let modifiers = "cancelShortcutModifiers"
		static let display = "cancelShortcutDisplay"
	}

	var cancelShortcut: CancelShortcutBinding {
		get {
			guard let keyCode = defaults.object(forKey: CancelKey.keyCode) as? Int,
				let code = UInt16(exactly: keyCode)
			else { return .escape }
			let modifiers = NSEvent.ModifierFlags(
				rawValue: UInt(defaults.object(forKey: CancelKey.modifiers) as? Int ?? 0))
			let display = defaults.string(forKey: CancelKey.display) ?? "?"
			return CancelShortcutBinding(keyCode: code, modifiers: modifiers, display: display)
		}
		nonmutating set {
			if newValue == .escape {
				resetCancelShortcut()
				return
			}
			defaults.set(Int(newValue.keyCode), forKey: CancelKey.keyCode)
			defaults.set(Int(newValue.modifiers.rawValue), forKey: CancelKey.modifiers)
			defaults.set(newValue.display, forKey: CancelKey.display)
		}
	}

	func resetCancelShortcut() {
		defaults.removeObject(forKey: CancelKey.keyCode)
		defaults.removeObject(forKey: CancelKey.modifiers)
		defaults.removeObject(forKey: CancelKey.display)
	}
}

/// Watches for the cancel shortcut only while a recording session is active, so the key is
/// never observed (or swallowed locally) outside of dictation.
@MainActor
final class CancelShortcutMonitor {
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private let onCancel: @MainActor () -> Void
	private let binding: () -> CancelShortcutBinding

	var isActive: Bool { globalMonitor != nil || localMonitor != nil }

	init(
		binding: @escaping () -> CancelShortcutBinding = { RecordingControlSettings().cancelShortcut },
		onCancel: @escaping @MainActor () -> Void
	) {
		self.binding = binding
		self.onCancel = onCancel
	}

	func setActive(_ active: Bool) {
		if active {
			install()
		} else {
			remove()
		}
	}

	private func install() {
		guard !isActive else { return }
		let binding = self.binding()
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard binding.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return
			}
			Task { @MainActor in self?.onCancel() }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard binding.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return event
			}
			Task { @MainActor in self?.onCancel() }
			return nil
		}
		AppLogger.shared.general.debug("Cancel shortcut monitor installed for \(binding.display)")
	}

	private func remove() {
		if let globalMonitor {
			NSEvent.removeMonitor(globalMonitor)
		}
		if let localMonitor {
			NSEvent.removeMonitor(localMonitor)
		}
		let wasActive = isActive
		globalMonitor = nil
		localMonitor = nil
		if wasActive {
			AppLogger.shared.general.debug("Cancel shortcut monitor removed")
		}
	}
}
