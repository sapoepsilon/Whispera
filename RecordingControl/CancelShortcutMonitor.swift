import AppKit

enum CancelShortcut {
	static let escapeKeyCode: UInt16 = 53

	static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
		keyCode == escapeKeyCode
			&& modifiers.intersection([.command, .option, .control, .shift]).isEmpty
	}
}

/// Watches for Escape only while a recording session is active, so the key is
/// never observed (or swallowed locally) outside of dictation.
@MainActor
final class CancelShortcutMonitor {
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private let onCancel: @MainActor () -> Void

	var isActive: Bool { globalMonitor != nil || localMonitor != nil }

	init(onCancel: @escaping @MainActor () -> Void) {
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
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard CancelShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return
			}
			Task { @MainActor in self?.onCancel() }
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard CancelShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
				return event
			}
			Task { @MainActor in self?.onCancel() }
			return nil
		}
		AppLogger.shared.general.debug("Cancel shortcut monitor installed")
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
