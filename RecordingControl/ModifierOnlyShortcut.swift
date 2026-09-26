import AppKit
import Combine
import SwiftUI

/// A dictation shortcut that is one modifier key on its own, such as Right Command or Fn/Globe.
/// These keys send only flagsChanged events, never keyDown, and Carbon hotkeys cannot bind
/// them, so they are watched by their own monitor. Left-side modifiers are left out: they are
/// part of nearly every app shortcut.
enum ModifierOnlyShortcut: String, CaseIterable, Sendable {
	case rightCommand = "Right Command"
	case rightOption = "Right Option"
	case rightControl = "Right Control"
	case rightShift = "Right Shift"
	case fn = "Globe"

	/// Also reads "Fn" and "🌐", which older recorders stored for the Globe key.
	init?(stored: String) {
		let trimmed = stored.trimmingCharacters(in: .whitespaces)
		if let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
			self = match
		} else if trimmed.caseInsensitiveCompare("Fn") == .orderedSame || trimmed == "🌐" {
			self = .fn
		} else {
			return nil
		}
	}

	init?(keyCode: UInt16) {
		guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
		self = match
	}

	var keyCode: UInt16 {
		switch self {
		case .rightCommand: return 54
		case .rightOption: return 61
		case .rightControl: return 62
		case .rightShift: return 60
		case .fn: return 63
		}
	}

	/// The device-independent flag this key sets.
	var modifierFlag: NSEvent.ModifierFlags {
		switch self {
		case .rightCommand: return .command
		case .rightOption: return .option
		case .rightControl: return .control
		case .rightShift: return .shift
		case .fn: return .function
		}
	}

	/// NX_DEVICER*KEYMASK: the device-dependent bit that tells the right key from the left one.
	private var deviceMask: UInt? {
		switch self {
		case .rightCommand: return 0x10
		case .rightOption: return 0x40
		case .rightControl: return 0x2000
		case .rightShift: return 0x04
		case .fn: return nil
		}
	}

	func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
		guard let deviceMask else { return flags.contains(.function) }
		return flags.rawValue & deviceMask != 0
	}

	/// Command, Option, Control or Shift held besides this key.
	func otherModifiers(in flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
		flags.intersection(ShortcutCombo.relevantModifiers).subtracting(modifierFlag)
	}

	/// How long a push-to-talk press must last before the microphone opens. Shift and Option are
	/// held for capital letters and accented characters, so they wait long enough to cover a
	/// typed character; Command, Control and Fn chords are shortcuts pressed in quick succession.
	var holdStartDelay: TimeInterval {
		switch self {
		case .rightShift, .rightOption: return 0.2
		case .rightCommand, .rightControl, .fn: return 0.12
		}
	}

	var displayName: String {
		switch self {
		case .rightCommand: return String(localized: "Right ⌘")
		case .rightOption: return String(localized: "Right ⌥")
		case .rightControl: return String(localized: "Right ⌃")
		case .rightShift: return String(localized: "Right ⇧")
		case .fn: return String(localized: "Fn (Globe)")
		}
	}
}

/// How a stored dictation shortcut is shown to people.
enum ShortcutDisplay {
	static func text(for stored: String) -> String {
		ModifierOnlyShortcut(stored: stored)?.displayName ?? stored
	}
}

/// One event seen by the single-key shortcut monitors.
struct ModifierOnlyInput: Equatable {
	enum Kind: Equatable {
		case flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags)
		case keyDown
	}

	let kind: Kind
	/// Posted by Whispera itself (a paste, typed text, a correction), not typed by the user.
	var isSelfPosted = false

	init(kind: Kind, isSelfPosted: Bool = false) {
		self.kind = kind
		self.isSelfPosted = isSelfPosted
	}

	init?(event: NSEvent) {
		switch event.type {
		case .flagsChanged: kind = .flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
		case .keyDown: kind = .keyDown
		default: return nil
		}
		isSelfPosted = SyntheticKeyEvent.isSelfPosted(event)
	}
}

/// Follows one modifier key through flagsChanged and keyDown events.
struct ModifierOnlyKeyTracker {
	enum Event: Equatable {
		case pressed
		case released
		/// Another key or modifier joined while the key was held: it is part of a combination
		/// such as Right ⌘C or Right ⌥L for @, not a dictation press.
		case interrupted
		case none
	}

	let key: ModifierOnlyShortcut
	private(set) var isDown = false
	private var isInterrupted = false

	init(key: ModifierOnlyShortcut) {
		self.key = key
	}

	/// Whispera's own keystrokes are ignored: pasting a live segment or an earlier dictation
	/// while the key is held is not the user pressing another key.
	mutating func handle(_ input: ModifierOnlyInput) -> Event {
		guard !input.isSelfPosted else { return .none }
		switch input.kind {
		case .flagsChanged(let keyCode, let flags): return flagsChanged(keyCode: keyCode, flags: flags)
		case .keyDown: return keyDown()
		}
	}

	mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Event {
		if keyCode == key.keyCode {
			let down = key.isDown(in: flags)
			if down, !isDown {
				// Pressed as the second key of a combination, such as ⌘ then Right ⌥
				guard key.otherModifiers(in: flags).isEmpty else { return .none }
				isDown = true
				isInterrupted = false
				return .pressed
			}
			if !down, isDown {
				isDown = false
				isInterrupted = false
				return .released
			}
			return .none
		}
		return interruptIfHeld()
	}

	mutating func keyDown() -> Event {
		interruptIfHeld()
	}

	mutating func reset() {
		isDown = false
		isInterrupted = false
	}

	private mutating func interruptIfHeld() -> Event {
		guard isDown, !isInterrupted else { return .none }
		isInterrupted = true
		return .interrupted
	}
}

/// Turns modifier-key presses into activation steps. A modifier is also typed as part of other
/// shortcuts, so anything that could end a recording or start one in toggle mode waits for a
/// clean release, and a recording started on press is cancelled when the press turns out to be
/// part of a combination. In the hold modes the start also waits a moment, so a key held for a
/// capital letter or a shortcut never opens the microphone at all.
struct ModifierOnlyPressRouter {
	enum Step: Equatable {
		case keyDown
		case keyUp
		case cancelSession
		/// Call `startDelayElapsed(press:isSessionActive:)` after `delay` to learn whether to start.
		case scheduleStart(press: Int, delay: TimeInterval)
	}

	private var deferredToRelease = false
	private var startedOnPress = false
	private var pendingStart: Int?
	private var pressMode: ActivationMode = .toggle
	private var pressCount = 0

	var isStartPending: Bool { pendingStart != nil }

	mutating func pressed(mode: ActivationMode, isSessionActive: Bool, startDelay: TimeInterval = 0) -> [Step] {
		reset()
		pressCount += 1
		pressMode = mode
		if isSessionActive || mode == .toggle {
			deferredToRelease = true
			return []
		}
		if startDelay > 0 {
			pendingStart = pressCount
			return [.scheduleStart(press: pressCount, delay: startDelay)]
		}
		startedOnPress = true
		return [.keyDown]
	}

	/// The key is still held with nothing else pressed, so this is a dictation press after all.
	/// A recording started some other way in the meantime is left alone rather than stopped.
	mutating func startDelayElapsed(press: Int, isSessionActive: Bool) -> [Step] {
		guard pendingStart == press else { return [] }
		pendingStart = nil
		guard !isSessionActive else { return [] }
		startedOnPress = true
		return [.keyDown]
	}

	mutating func released() -> [Step] {
		defer { reset() }
		if startedOnPress { return [.keyUp] }
		if deferredToRelease { return [.keyDown, .keyUp] }
		// A tap shorter than the start delay: Hold or Toggle treats a tap as "start and keep
		// recording", while Push to Talk would only record a blip, so it does nothing.
		if pendingStart != nil, pressMode == .holdOrToggle { return [.keyDown, .keyUp] }
		return []
	}

	mutating func interrupted() -> [Step] {
		let started = startedOnPress
		reset()
		return started ? [.cancelSession] : []
	}

	mutating func reset() {
		deferredToRelease = false
		startedOnPress = false
		pendingStart = nil
	}
}

/// Everything the single-key monitors decide, from raw event to activation steps.
struct ModifierOnlyShortcutMachine {
	private(set) var tracker: ModifierOnlyKeyTracker
	private(set) var router = ModifierOnlyPressRouter()

	init(key: ModifierOnlyShortcut) {
		tracker = ModifierOnlyKeyTracker(key: key)
	}

	var key: ModifierOnlyShortcut { tracker.key }

	/// `recorderListening`: a shortcut recorder owns the key presses, so they are not acted on,
	/// and a press it swallowed leaves nothing behind for its release to act on later. The mode
	/// and session state are read only for a press, since every keystroke in every app lands here.
	mutating func handle(
		_ input: ModifierOnlyInput, recorderListening: Bool, mode: @autoclosure () -> ActivationMode,
		isSessionActive: @autoclosure () -> Bool
	) -> [ModifierOnlyPressRouter.Step] {
		if recorderListening {
			reset()
			return []
		}
		switch tracker.handle(input) {
		case .pressed:
			return router.pressed(mode: mode(), isSessionActive: isSessionActive(), startDelay: key.holdStartDelay)
		case .released:
			return router.released()
		case .interrupted:
			return router.interrupted()
		case .none:
			return []
		}
	}

	mutating func startDelayElapsed(press: Int, isSessionActive: Bool) -> [ModifierOnlyPressRouter.Step] {
		router.startDelayElapsed(press: press, isSessionActive: isSessionActive)
	}

	mutating func reset() {
		tracker.reset()
		router.reset()
	}
}

/// Recognizes a modifier key pressed and released on its own while a shortcut recorder listens.
struct ModifierOnlyRecording {
	private var candidate: ModifierOnlyShortcut?

	/// The key, once it has been released without anything else pressed in between.
	mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ModifierOnlyShortcut? {
		if let candidate {
			self.candidate = nil
			guard keyCode == candidate.keyCode, !candidate.isDown(in: flags) else { return nil }
			return candidate
		}
		if let key = ModifierOnlyShortcut(keyCode: keyCode), key.isDown(in: flags),
			key.otherModifiers(in: flags).isEmpty
		{
			candidate = key
		}
		return nil
	}

	mutating func keyDown() {
		candidate = nil
	}
}

/// What macOS does with the Globe key ("Press 🌐 key to" in Keyboard settings). Anything but
/// Do Nothing also fires with every dictation press.
enum GlobeKeySetting {
	static func usage() -> Int? {
		CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
	}

	/// An unset value means the macOS default, which is not Do Nothing.
	static func isClaimedBySystem(usage: Int?) -> Bool {
		usage != 0
	}

	static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// Explains what a single-key dictation shortcut does, shown under the shortcut recorders.
struct ModifierOnlyShortcutNotes: View {
	let shortcut: String
	@State private var globeClaimed = GlobeKeySetting.isClaimedBySystem(usage: GlobeKeySetting.usage())

	var body: some View {
		if let key = ModifierOnlyShortcut(stored: shortcut) {
			VStack(alignment: .leading, spacing: 6) {
				Text(
					"Pressing another key while holding \(key.displayName) cancels it, so shortcuts and characters typed with it do not start dictation."
				)
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				if key == .fn, globeClaimed {
					HStack(alignment: .top, spacing: 6) {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundColor(.orange)
						Text(
							"macOS also acts on the Globe key. In System Settings > Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\" so it only starts dictation."
						)
						.font(.caption)
						.fixedSize(horizontal: false, vertical: true)
					}
					Button("Open Keyboard Settings") {
						NSWorkspace.shared.open(GlobeKeySetting.keyboardSettingsURL)
					}
					.controlSize(.small)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
				_ in
				globeClaimed = GlobeKeySetting.isClaimedBySystem(usage: GlobeKeySetting.usage())
			}
		}
	}
}
