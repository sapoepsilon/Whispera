import AppKit
import Carbon

enum CancelShortcut {
	static let escapeKeyCode: UInt16 = 53

	static func matches(
		keyCode: UInt16, modifiers: NSEvent.ModifierFlags, binding: CancelShortcutBinding = .escape
	) -> Bool {
		binding.matches(keyCode: keyCode, modifiers: modifiers)
	}

	static let carbonSpec = CarbonHotKeySpec(keyCode: UInt32(escapeKeyCode), modifiers: 0)

	static func carbonSpec(for binding: CancelShortcutBinding) -> CarbonHotKeySpec? {
		binding == .escape
			? carbonSpec : CarbonHotKeyMapping.spec(keyCode: binding.keyCode, modifiers: binding.modifiers)
	}

	/// The event monitor and the Carbon hotkey can both report one Escape press around a
	/// secure input transition; a second cancel would reach an earlier transcription.
	static let duplicateWindow: TimeInterval = 0.3
}

enum CancelShortcutPolicy {
	/// Armed only while the microphone is capturing. Transcription and the LLM wait can take
	/// many seconds, by which time an Esc is usually meant for the app in front (leaving vim
	/// insert mode, closing a popup), and it would throw the dictation away. The pill and the
	/// menu bar keep a cancel button for that phase.
	static func shouldListen(isRecording: Bool, isStarting: Bool, enabled: Bool) -> Bool {
		enabled && (isRecording || isStarting)
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
			display: ShortcutDisplayFormatter.format(modifiers: relevant, key: key))
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
/// never observed (or swallowed locally) outside of dictation. Global monitors go blind under
/// Secure Input, so while it is on the shortcut is also claimed as a Carbon hotkey, which
/// keeps working.
@MainActor
final class CancelShortcutMonitor {
	static let secureInputPollInterval: TimeInterval = 0.5

	private var globalMonitor: Any?
	private var localMonitor: Any?
	private let onCancel: @MainActor () -> Void
	private let isSecureInputEnabled: () -> Bool
	private let secureInputHotKey = CarbonHotKey()
	private var secureInputTimer: Timer?
	private var lastCancelAt: Date?
	private let binding: () -> CancelShortcutBinding
	private var installedBinding: CancelShortcutBinding = .escape

	var isActive: Bool { globalMonitor != nil || localMonitor != nil }
	var isSecureInputHotKeyRegistered: Bool { secureInputHotKey.registeredSpec != nil }

	init(
		binding: @escaping () -> CancelShortcutBinding = { RecordingControlSettings().cancelShortcut },
		isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
		onCancel: @escaping @MainActor () -> Void
	) {
		self.binding = binding
		self.isSecureInputEnabled = isSecureInputEnabled
		self.onCancel = onCancel
		secureInputHotKey.action = { [weak self] in
			MainActor.assumeIsolated { self?.fire() }
		}
	}

	/// Re-checks Secure Input and claims or releases the cancel shortcut as a Carbon hotkey.
	func reconcileSecureInput() {
		guard isActive, isSecureInputEnabled() else {
			secureInputHotKey.unregister()
			return
		}
		if !isSecureInputHotKeyRegistered {
			guard let spec = CancelShortcut.carbonSpec(for: installedBinding) else {
				AppLogger.shared.general.error("The cancel shortcut cannot be a system hotkey under secure input")
				return
			}
			if secureInputHotKey.register(spec) {
				AppLogger.shared.general.info("Secure input on; cancel shortcut claimed as a system hotkey")
			} else {
				AppLogger.shared.general.error("Could not register the cancel shortcut under secure input")
			}
		}
	}

	/// A key press both monitors act on: the installed shortcut, typed by the user rather than
	/// posted by Whispera's own text insertion.
	nonisolated static func isCancelPress(_ event: NSEvent, binding: CancelShortcutBinding) -> Bool {
		binding.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) && !SyntheticKeyEvent.isSelfPosted(event)
	}

	/// What either monitor does with a key press; true when it cancelled.
	@discardableResult
	func receive(_ event: NSEvent, now: Date = Date()) -> Bool {
		guard isActive, Self.isCancelPress(event, binding: installedBinding) else { return false }
		fire(now: now)
		return true
	}

	func fire(now: Date = Date()) {
		if let lastCancelAt, now.timeIntervalSince(lastCancelAt) < CancelShortcut.duplicateWindow { return }
		lastCancelAt = now
		onCancel()
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
		installedBinding = binding
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard Self.isCancelPress(event, binding: binding) else { return }
			Task { @MainActor in self?.fire() }
		}
		// Local monitors run on the main thread, and a cancel press is swallowed
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			MainActor.assumeIsolated { self?.receive(event) ?? false } ? nil : event
		}
		reconcileSecureInput()
		let timer = Timer(timeInterval: Self.secureInputPollInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.reconcileSecureInput() }
		}
		timer.tolerance = 0.2
		RunLoop.main.add(timer, forMode: .common)
		secureInputTimer = timer
		AppLogger.shared.general.debug("Cancel shortcut monitor installed for \(binding.display)")
	}

	private func remove() {
		secureInputTimer?.invalidate()
		secureInputTimer = nil
		secureInputHotKey.unregister()
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
