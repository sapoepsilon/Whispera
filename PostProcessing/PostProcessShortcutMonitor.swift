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
	private var defaultsObserver: NSObjectProtocol?
	private var installedSignature: String?
	private let settings: PostProcessingSettings
	private let logger = AppLogger.shared.general

	init(settings: PostProcessingSettings = PostProcessingSettings()) {
		self.settings = settings
		defaultsObserver = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.reinstallIfChanged()
		}
	}

	deinit {
		removeMonitors()
		if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
	}

	func attach(audioManager: AudioManager, parser: @escaping ShortcutParser) {
		self.audioManager = audioManager
		self.parser = parser
		reinstall()
	}

	/// Global monitors installed before Accessibility is granted stay deaf, so the owner calls
	/// this again once permission arrives.
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
		let signature = "\(settings.isEnabled)|\(shortcut)|\(AXIsProcessTrusted())"
		guard signature != installedSignature, let parser else { return }
		installedSignature = signature
		removeMonitors()

		guard settings.isEnabled, Self.isUsableShortcut(shortcut) else { return }
		let (modifiers, keyCode) = parser(shortcut)
		let matches: (NSEvent) -> Bool = { event in
			event.keyCode == keyCode
				&& event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifiers
		}

		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			if matches(event) { self?.trigger() }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard matches(event) else { return event }
			self?.trigger()
			return nil
		}
		logger.info("Post-processing shortcut installed for \(shortcut)")
	}

	private func trigger() {
		logger.info("Post-processing shortcut detected")
		Task { @MainActor [weak self] in
			if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
				NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
			}
			self?.audioManager?.toggleRecording(postProcess: true)
		}
	}

	private func removeMonitors() {
		if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
		if let localMonitor { NSEvent.removeMonitor(localMonitor) }
		globalMonitor = nil
		localMonitor = nil
	}
}
