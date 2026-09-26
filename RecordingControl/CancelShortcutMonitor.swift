import AppKit
import Carbon

enum CancelShortcut {
	static let escapeKeyCode: UInt16 = 53

	static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
		keyCode == escapeKeyCode
			&& modifiers.intersection([.command, .option, .control, .shift]).isEmpty
	}

	static let carbonSpec = CarbonHotKeySpec(keyCode: UInt32(escapeKeyCode), modifiers: 0)

	/// The event monitor and the Carbon hotkey can both report one Escape press around a
	/// secure input transition; a second cancel would reach an earlier transcription.
	static let duplicateWindow: TimeInterval = 0.3
}

/// Watches for Escape only while a recording session is active, so the key is
/// never observed (or swallowed locally) outside of dictation. Global monitors go
/// blind under Secure Input, so while it is on Escape is also claimed as a Carbon
/// hotkey, which keeps working.
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

	var isActive: Bool { globalMonitor != nil || localMonitor != nil }
	var isSecureInputHotKeyRegistered: Bool { secureInputHotKey.registeredSpec != nil }

	init(
		isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
		onCancel: @escaping @MainActor () -> Void
	) {
		self.isSecureInputEnabled = isSecureInputEnabled
		self.onCancel = onCancel
		secureInputHotKey.action = { [weak self] in
			MainActor.assumeIsolated { self?.fire() }
		}
	}

	/// Re-checks Secure Input and claims or releases the Carbon Escape hotkey.
	func reconcileSecureInput() {
		guard isActive, isSecureInputEnabled() else {
			secureInputHotKey.unregister()
			return
		}
		if !isSecureInputHotKeyRegistered {
			if secureInputHotKey.register(CancelShortcut.carbonSpec) {
				AppLogger.shared.general.info("Secure input on; cancel shortcut claimed as a system hotkey")
			} else {
				AppLogger.shared.general.error("Could not register the cancel shortcut under secure input")
			}
		}
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
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard CancelShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return
			}
			Task { @MainActor in self?.fire() }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard CancelShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return event
			}
			Task { @MainActor in self?.fire() }
			return nil
		}
		reconcileSecureInput()
		let timer = Timer(timeInterval: Self.secureInputPollInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.reconcileSecureInput() }
		}
		timer.tolerance = 0.2
		RunLoop.main.add(timer, forMode: .common)
		secureInputTimer = timer
		AppLogger.shared.general.debug("Cancel shortcut monitor installed")
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
