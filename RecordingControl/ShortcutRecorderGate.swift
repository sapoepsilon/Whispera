import Foundation

/// Pauses the dictation shortcuts while a shortcut recorder listens. Recording the current key
/// again (tapping Right ⌘ to re-pick Right ⌘) would otherwise also start a dictation, because
/// the recorder and the live shortcut monitors see the same key press.
@MainActor
final class ShortcutRecorderGate {
	static let shared = ShortcutRecorderGate()

	private var listeners: Set<UUID> = []

	var isRecording: Bool { !listeners.isEmpty }

	/// Returns a token for `end(_:)`. Each recorder holds its own, so one closing never
	/// resumes the shortcuts while another is still listening.
	func begin() -> UUID {
		let token = UUID()
		listeners.insert(token)
		return token
	}

	func end(_ token: UUID?) {
		guard let token else { return }
		listeners.remove(token)
	}
}
