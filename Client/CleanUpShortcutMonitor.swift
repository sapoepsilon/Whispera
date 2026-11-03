import AppKit
import Foundation

/// Second global hotkey: dictate and run the Clean up recipe on that dictation.
/// Installed only while the Clean up shortcut is on so the default binding never steals a key
/// from users who have not opted in.
final class CleanUpShortcutMonitor {
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private weak var audioManager: AudioManager?
	private var defaultsObserver: DefaultsKeyObserver?
	private var installedSignature: String?
	private let carbonHotKey = CarbonHotKey()
	@MainActor private var activation = ActivationStateMachine(
		mode: .toggle, holdThreshold: TimeInterval(RecordingControlSettings.defaultHoldThresholdMs) / 1000)
	private let settings: CleanUpSettings
	private let logger = AppLogger.shared.general

	init(settings: CleanUpSettings = CleanUpSettings()) {
		self.settings = settings
		defaultsObserver = DefaultsKeyObserver(
			defaults: settings.defaults,
			keys: [CleanUpSettings.Key.onRequestEnabled, CleanUpSettings.Key.shortcut]
		) { [weak self] in
			self?.reinstallIfChanged()
		}
	}

	deinit {
		removeMonitors()
	}

	func attach(audioManager: AudioManager) {
		self.audioManager = audioManager
		reinstall()
	}

	/// Global monitors installed before Accessibility is granted stay deaf, so the owner calls
	/// this again whenever it reinstalls its own shortcut monitors, including after permission arrives.
	func reinstall() {
		installedSignature = nil
		reinstallIfChanged()
	}

	static func isUsableShortcut(_ shortcut: String) -> Bool {
		ShortcutCombo(shortcut) != nil
	}

	/// The other Whispera shortcut that is the same key combination, if any. The Clean up
	/// hotkey swallows its keystroke, so a clash would take over the dictation or file shortcut.
	static func conflictingShortcut(for shortcut: String, defaults: UserDefaults = .standard) -> String? {
		guard let combo = ShortcutCombo(shortcut) else { return nil }
		let others = [
			ShortcutDefaults.dictation(in: defaults),
			ShortcutDefaults.fileSelection(in: defaults),
		]
		if let clash = others.first(where: { ShortcutCombo($0) == combo }) {
			return clash
		}
		let cancel = RecordingControlSettings(defaults: defaults).cancelShortcut
		return cancel.matches(keyCode: combo.keyCode, modifiers: combo.modifiers) ? cancel.display : nil
	}

	private func reinstallIfChanged() {
		let shortcut = settings.shortcut
		let needsKeyRelease = RecordingControlSettings().activationMode.needsKeyRelease
		let conflict = Self.conflictingShortcut(for: shortcut, defaults: settings.defaults)
		let signature =
			"\(settings.isOnRequestEnabled)|\(shortcut)|\(AXIsProcessTrusted())|\(needsKeyRelease)|\(conflict ?? "")"
		guard signature != installedSignature, audioManager != nil else { return }
		installedSignature = signature
		removeMonitors()
		// A release in flight is lost when the monitors are replaced
		Task { @MainActor [weak self] in self?.activation.reset() }

		guard settings.isOnRequestEnabled else { return }
		guard let combo = ShortcutCombo(shortcut) else {
			logger.error("Clean up shortcut '\(shortcut)' names an unknown key; not installed")
			return
		}
		if let conflict {
			logger.error("Clean up shortcut \(shortcut) is the same as \(conflict); not installed")
			return
		}
		let (modifiers, keyCode) = (combo.modifiers, combo.keyCode)

		// A system hotkey swallows the keystroke, so the default Option-Shift-Space no longer types
		// non-breaking spaces into the focused app; this holds whichever backend dictation uses
		if let spec = CarbonHotKeyMapping.spec(keyCode: keyCode, modifiers: modifiers) {
			carbonHotKey.action = { [weak self] in self?.handlePress(isRepeat: false) }
			carbonHotKey.releaseAction = { [weak self] in self?.handleRelease() }
			if carbonHotKey.register(spec) {
				logger.info("Clean up shortcut registered as a system hotkey for \(shortcut)")
				return
			}
			logger.error("Clean up system hotkey unavailable, using event monitors")
		}

		let matches: (NSEvent) -> Bool = { event in
			event.keyCode == keyCode
				&& event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifiers
		}

		// A system-wide key-up monitor wakes the app on every keystroke, so toggle mode skips it
		let globalMask: NSEvent.EventTypeMask = needsKeyRelease ? [.keyDown, .keyUp] : .keyDown
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) { [weak self] event in
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return }
			if event.type == .keyUp {
				if event.keyCode == keyCode { self?.handleRelease() }
				return
			}
			if matches(event) { self?.handlePress(isRepeat: event.isARepeat) }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
			guard !SyntheticKeyEvent.isSelfPosted(event) else { return event }
			if event.type == .keyUp {
				if event.keyCode == keyCode { self?.handleRelease() }
				return event
			}
			guard matches(event) else { return event }
			self?.handlePress(isRepeat: event.isARepeat)
			return nil
		}
		logger.info("Clean up shortcut installed for \(shortcut)")
	}

	/// Follows the same activation mode as the dictation shortcut, so push-to-talk and
	/// hold-or-toggle work here too and key repeat never re-toggles recording.
	private func handlePress(isRepeat: Bool) {
		let pressedAt = Date()
		if !isRepeat {
			logger.info("Clean up shortcut detected")
		}
		Task { @MainActor [weak self] in
			guard let self, let audioManager = self.audioManager, !ShortcutRecorderGate.shared.isRecording else {
				return
			}
			let recording = RecordingControlSettings()
			self.activation.mode = recording.activationMode
			self.activation.holdThreshold = recording.holdThreshold
			let action = self.activation.keyDown(
				at: pressedAt, isRepeat: isRepeat, isSessionActive: audioManager.isSessionActive)
			self.perform(action, on: audioManager)
		}
	}

	private func handleRelease() {
		let releasedAt = Date()
		Task { @MainActor [weak self] in
			guard let self, let audioManager = self.audioManager else { return }
			let action = self.activation.keyUp(at: releasedAt, isSessionActive: audioManager.isSessionActive)
			self.perform(action, on: audioManager)
		}
	}

	@MainActor
	private func perform(_ action: ActivationAction, on audioManager: AudioManager) {
		guard action != .none else { return }
		if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
			NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
		}
		switch action {
		case .start:
			audioManager.startRecordingSession(postProcess: true)
		case .stop:
			audioManager.requestStop()
		case .none:
			break
		}
	}

	private func removeMonitors() {
		if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
		if let localMonitor { NSEvent.removeMonitor(localMonitor) }
		globalMonitor = nil
		localMonitor = nil
		carbonHotKey.unregister()
	}
}

enum ShortcutDisplayFormatter {
	/// Produces the symbol string `ShortcutCombo` reads back to the same key code. The key is
	/// named from its key code, so Shift never turns "1" into "!" and F-keys keep their names.
	/// Nil when there are no modifiers or the key has no name.
	static func format(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
		let flags = modifiers.intersection(ShortcutCombo.relevantModifiers)
		guard !flags.isEmpty, let key = ShortcutKeyCodes.keyName(forKeyCode: keyCode) else { return nil }
		return format(modifiers: flags, key: key)
	}

	static func format(modifiers: NSEvent.ModifierFlags, key: String) -> String {
		var parts = ""
		if modifiers.contains(.command) { parts += "⌘" }
		if modifiers.contains(.option) { parts += "⌥" }
		if modifiers.contains(.control) { parts += "⌃" }
		if modifiers.contains(.shift) { parts += "⇧" }
		return parts + key
	}
}
