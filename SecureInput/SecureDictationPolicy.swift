import Carbon
import Foundation

/// What a finished dictation may do with its text. Secure Event Input is on while a password
/// field (or a password manager, or a terminal's secure keyboard entry) has focus, so a
/// dictation that lands there is treated as a secret: it is pasted and then forgotten.
struct SecureDictationPolicy: Equatable, Sendable {
	let postProcess: Bool
	let rememberAsLastTranscription: Bool
	let saveToHistory: Bool
	/// Clipboard writes carry the concealed and transient markers so clipboard managers skip them.
	let concealClipboard: Bool

	/// The menu bar message for a post-processing request that Secure Input overrode, so the
	/// raw paste is not mistaken for a broken LLM setup.
	static func skippedPostProcessingNotice(postProcessRequested: Bool, secureInput: Bool) -> String? {
		guard postProcessRequested, secureInput else { return nil }
		return String(
			localized:
				"Secure Input was on, so this dictation was pasted as spoken: it was not post-processed or saved to history."
		)
	}

	static func resolve(postProcessRequested: Bool, secureInput: Bool) -> SecureDictationPolicy {
		SecureDictationPolicy(
			postProcess: postProcessRequested && !secureInput,
			rememberAsLastTranscription: !secureInput,
			saveToHistory: !secureInput,
			concealClipboard: secureInput
		)
	}
}

enum SecureDictation {
	nonisolated(unsafe) static var probe: () -> Bool = { IsSecureEventInputEnabled() }

	static var isSecureInputActive: Bool { probe() }
}
