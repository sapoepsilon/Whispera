import Foundation

/// UserDefaults-backed post-processing configuration. API keys are deliberately not stored here;
/// they live in the Keychain via `PostProcessingSecretStore`.
struct PostProcessingSettings {
	enum Key {
		static let enabled = "postProcessingEnabled"
		static let applyToEveryDictation = "postProcessingApplyToEveryDictation"
		static let shortcut = "postProcessingShortcut"
		static let providerID = "postProcessingProviderID"
		static let models = "postProcessingModels"
		static let baseURLs = "postProcessingBaseURLs"
		static let prompts = "postProcessingPrompts"
		static let selectedPromptID = "postProcessingSelectedPromptID"
		static let timeoutSeconds = "postProcessingTimeoutSeconds"
	}

	static let defaultShortcut = "⌥⇧Space"
	static let defaultProviderID = "openai"
	static let defaultTimeoutSeconds = 30.0

	let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var isEnabled: Bool {
		get { defaults.bool(forKey: Key.enabled) }
		nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
	}

	var appliesToEveryDictation: Bool {
		get { defaults.bool(forKey: Key.applyToEveryDictation) }
		nonmutating set { defaults.set(newValue, forKey: Key.applyToEveryDictation) }
	}

	var shortcut: String {
		get { defaults.string(forKey: Key.shortcut) ?? Self.defaultShortcut }
		nonmutating set { defaults.set(newValue, forKey: Key.shortcut) }
	}

	var providerID: String {
		get {
			let stored = defaults.string(forKey: Key.providerID) ?? Self.defaultProviderID
			return PostProcessingProvider.provider(withID: stored) == nil ? Self.defaultProviderID : stored
		}
		nonmutating set { defaults.set(newValue, forKey: Key.providerID) }
	}

	var provider: PostProcessingProvider {
		PostProcessingProvider.provider(withID: providerID) ?? PostProcessingProvider.all[0]
	}

	var timeoutSeconds: Double {
		get {
			let value = defaults.double(forKey: Key.timeoutSeconds)
			return value > 0 ? value : Self.defaultTimeoutSeconds
		}
		nonmutating set { defaults.set(newValue, forKey: Key.timeoutSeconds) }
	}

	func model(for providerID: String) -> String {
		(defaults.dictionary(forKey: Key.models) as? [String: String])?[providerID] ?? ""
	}

	func setModel(_ model: String, for providerID: String) {
		var models = (defaults.dictionary(forKey: Key.models) as? [String: String]) ?? [:]
		models[providerID] = model.trimmingCharacters(in: .whitespacesAndNewlines)
		defaults.set(models, forKey: Key.models)
	}

	/// Only providers that allow editing honour a stored override; fixed presets always use their default.
	func baseURL(for provider: PostProcessingProvider) -> String {
		guard provider.allowsBaseURLEdit,
			let stored = (defaults.dictionary(forKey: Key.baseURLs) as? [String: String])?[provider.id],
			!stored.isEmpty
		else { return provider.defaultBaseURL }
		return stored
	}

	func setBaseURL(_ url: String, for providerID: String) {
		var urls = (defaults.dictionary(forKey: Key.baseURLs) as? [String: String]) ?? [:]
		urls[providerID] = url.trimmingCharacters(in: .whitespacesAndNewlines)
		defaults.set(urls, forKey: Key.baseURLs)
	}

	var prompts: [PostProcessingPrompt] {
		get {
			guard let data = defaults.data(forKey: Key.prompts),
				let decoded = try? JSONDecoder().decode([PostProcessingPrompt].self, from: data),
				!decoded.isEmpty
			else { return [.defaultCleanup] }
			return decoded
		}
		nonmutating set {
			let value = newValue.isEmpty ? [.defaultCleanup] : newValue
			if let data = try? JSONEncoder().encode(value) {
				defaults.set(data, forKey: Key.prompts)
			}
		}
	}

	var selectedPromptID: String {
		get {
			let prompts = self.prompts
			if let stored = defaults.string(forKey: Key.selectedPromptID),
				prompts.contains(where: { $0.id == stored })
			{
				return stored
			}
			return prompts[0].id
		}
		nonmutating set { defaults.set(newValue, forKey: Key.selectedPromptID) }
	}

	var selectedPrompt: PostProcessingPrompt {
		let id = selectedPromptID
		return prompts.first { $0.id == id } ?? prompts[0]
	}

	/// Post-processing replaces the pasted text wholesale, which live mode cannot do because it
	/// types words as they are confirmed. So "every dictation" only covers text-mode sessions.
	func shouldPostProcess(requestedByShortcut: Bool, isLiveMode: Bool) -> Bool {
		if requestedByShortcut { return isEnabled }
		return isEnabled && appliesToEveryDictation && !isLiveMode
	}
}
