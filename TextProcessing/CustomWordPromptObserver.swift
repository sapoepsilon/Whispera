import Foundation

/// Reports when the decoder prompt built from the custom words changes, whichever part of the
/// app wrote them: Settings, a whispera:// link, the CLI, Raycast or an App Intent all write the
/// same defaults key, and only a stored-value observer sees every one of them.
final class CustomWordPromptObserver {
	private(set) var prompt: String?
	private var observer: DefaultsKeyObserver?

	init(defaults: UserDefaults = .standard, onChange: @escaping @MainActor () -> Void) {
		prompt = Self.effectivePrompt(in: defaults)
		observer = DefaultsKeyObserver(defaults: defaults, keys: TextProcessingSettings.decoderPromptKeys) {
			[weak self] in
			guard let self else { return }
			let current = Self.effectivePrompt(in: defaults)
			// Reordering or re-adding a word writes the key without changing the prompt
			guard current != self.prompt else { return }
			self.prompt = current
			onChange()
		}
	}

	/// The prompt Whisper should get, or nil when biasing is off or there are no words.
	static func effectivePrompt(in defaults: UserDefaults) -> String? {
		guard TextProcessingSettings.biasDecodingWithCustomWords(from: defaults) else { return nil }
		return TextProcessingSettings.decoderPrompt(for: TextProcessingSettings.customWords(from: defaults))
	}
}
