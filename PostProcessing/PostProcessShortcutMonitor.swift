import AppKit
import Foundation

/// Second global hotkey: dictate and run the result through the post-processing provider.
/// Installed only while post-processing is enabled so the default binding never steals a key
/// from users who have not opted in.
final class PostProcessShortcutMonitor {
	typealias ShortcutParser = (String) -> (NSEvent.ModifierFlags, UInt16)

	private var globalMonitor: Any?
	private var localMonitor: Any?
	private weak var audioManager: AudioManager?
	private var parser: ShortcutParser?
	private var defaultsObserver: DefaultsKeyObserver?
	private var installedSignature: String?
	private let carbonHotKey = CarbonHotKey()
	@MainActor private var activation = ActivationStateMachine(
		mode: .toggle, holdThreshold: TimeInterval(RecordingControlSettings.defaultHoldThresholdMs) / 1000)
	private let settings: PostProcessingSettings
	private let logger = AppLogger.shared.general

	init(settings: PostProcessingSettings = PostProcessingSettings()) {
		self.settings = settings
		defaultsObserver = DefaultsKeyObserver(
			defaults: settings.defaults,
			keys: [PostProcessingSettings.Key.enabled, PostProcessingSettings.Key.shortcut]
		) { [weak self] in
			self?.reinstallIfChanged()
		}
	}

	deinit {
		removeMonitors()
	}

	func attach(audioManager: AudioManager, parser: @escaping ShortcutParser) {
		self.audioManager = audioManager
		self.parser = parser
		reinstall()
	}

	/// Global monitors installed before Accessibility is granted stay deaf, so the owner calls
	/// this again whenever it reinstalls its own shortcut monitors, including after permission arrives.
	func reinstall() {
		installedSignature = nil
		reinstallIfChanged()
	}

	static func isUsableShortcut(_ shortcut: String) -> Bool {
		let modifiers: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
		let key = shortcut.filter { !modifiers.contains($0) }.trimmingCharacters(in: .whitespaces)
		return !key.isEmpty
	}

	private func reinstallIfChanged() {
		let shortcut = settings.shortcut
		let needsKeyRelease = RecordingControlSettings().activationMode.needsKeyRelease
		let signature = "\(settings.isEnabled)|\(shortcut)|\(AXIsProcessTrusted())|\(needsKeyRelease)"
		guard signature != installedSignature, let parser else { return }
		installedSignature = signature
		removeMonitors()
		// A release in flight is lost when the monitors are replaced
		Task { @MainActor [weak self] in self?.activation.reset() }

		guard settings.isEnabled, Self.isUsableShortcut(shortcut) else { return }
		let (modifiers, keyCode) = parser(shortcut)

		// A system hotkey swallows the keystroke, so the default Option-Shift-Space no longer types
		// non-breaking spaces into the focused app; this holds whichever backend dictation uses
		if let spec = CarbonHotKeyMapping.spec(keyCode: keyCode, modifiers: modifiers) {
			carbonHotKey.action = { [weak self] in self?.handlePress(isRepeat: false) }
			carbonHotKey.releaseAction = { [weak self] in self?.handleRelease() }
			if carbonHotKey.register(spec) {
				logger.info("Post-processing shortcut registered as a system hotkey for \(shortcut)")
				return
			}
			logger.error("Post-processing system hotkey unavailable, using event monitors")
		}

		let matches: (NSEvent) -> Bool = { event in
			event.keyCode == keyCode
				&& event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifiers
		}

		// A system-wide key-up monitor wakes the app on every keystroke, so toggle mode skips it
		let globalMask: NSEvent.EventTypeMask = needsKeyRelease ? [.keyDown, .keyUp] : .keyDown
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) { [weak self] event in
			if event.type == .keyUp {
				if event.keyCode == keyCode { self?.handleRelease() }
				return
			}
			if matches(event) { self?.handlePress(isRepeat: event.isARepeat) }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
			if event.type == .keyUp {
				if event.keyCode == keyCode { self?.handleRelease() }
				return event
			}
			guard matches(event) else { return event }
			self?.handlePress(isRepeat: event.isARepeat)
			return nil
		}
		logger.info("Post-processing shortcut installed for \(shortcut)")
	}

	/// Follows the same activation mode as the dictation shortcut, so push-to-talk and
	/// hold-or-toggle work here too and key repeat never re-toggles recording.
	private func handlePress(isRepeat: Bool) {
		let pressedAt = Date()
		if !isRepeat {
			logger.info("Post-processing shortcut detected")
		}
		Task { @MainActor [weak self] in
			guard let self, let audioManager = self.audioManager else { return }
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
