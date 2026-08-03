// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where recipe LLM steps run. Mutually exclusive at the app-global level. WHI-39.
enum LLMMode: String, CaseIterable, Sendable {
	case local
	case byok

	var displayName: String {
		switch self {
		case .local: return "Local"
		case .byok: return "Bring Your Own Key"
		}
	}
}

extension WhisperaSettings {
	private static let llmModeKey = "whisperaLLMMode"
	private static let byokModelKey = "whisperaByokModel"

	/// Unknown raw values fall back to Local, so a persisted "subscription" from
	/// an older build silently degrades instead of trapping.
	static var llmMode: LLMMode {
		get { LLMMode(rawValue: UserDefaults.standard.string(forKey: llmModeKey) ?? "") ?? .local }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: llmModeKey) }
	}

	static let defaultByokModel = "gpt-4o-mini"

	/// Model used for BYOK steps that don't name one themselves.
	static var byokModel: String {
		get {
			let stored = UserDefaults.standard.string(forKey: byokModelKey) ?? ""
			return stored.isEmpty ? defaultByokModel : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: byokModelKey) }
	}
}

enum RecipeRouterError: LocalizedError {
	case notSignedIn
	case missingProviderKey(ProviderId)
	case executionFailed(String)

	var errorDescription: String? {
		switch self {
		case .notSignedIn:
			return "Subscription mode needs you to sign in (Account settings)."
		case .missingProviderKey(let provider):
			return "No \(provider.displayName) key saved. Add one in BYOK settings."
		case .executionFailed(let message):
			return message
		}
	}
}

protocol RecipeExecuting: Sendable {
	func run(recipe: Recipe, input: String) async throws -> String
}

extension LocalLLMExecutor: RecipeExecuting {}

/// Runs a recipe through the backend execute endpoint. Parked: the shipping app
/// has no account, so nothing constructs this today. Kept so the backend path
/// can be restored without rewriting it.
struct BackendExecutor: RecipeExecuting {
	let providerKey: String?
	private let api: WhisperaAPIClient

	init(providerKey: String?, api: WhisperaAPIClient = .shared) {
		self.providerKey = providerKey
		self.api = api
	}

	func run(recipe: Recipe, input: String) async throws -> String {
		let result = try await api.executeRecipe(id: recipe.id, input: input, providerKey: providerKey)
		guard result.status == "completed", let output = result.output, !output.isEmpty else {
			throw RecipeRouterError.executionFailed(result.error ?? "Recipe execution failed")
		}
		return output
	}
}

/// Resolves the active mode and runs a recipe through the right executor.
@MainActor
struct RecipeRouter {
	static let shared = RecipeRouter()

	/// Parked with the backend path — no mode consults it while the app ships
	/// without accounts.
	private let auth: AuthManager
	private let keyStore: ByokKeyStore
	private let modeProvider: () -> LLMMode

	init(
		auth: AuthManager = .shared,
		keyStore: ByokKeyStore = .shared,
		modeProvider: @escaping () -> LLMMode = { WhisperaSettings.llmMode }
	) {
		self.auth = auth
		self.keyStore = keyStore
		self.modeProvider = modeProvider
	}

	func run(recipe: Recipe, input: String) async throws -> String {
		try await executor(for: recipe).run(recipe: recipe, input: input)
	}

	/// Builds the executor for the current mode. BYOK keys are read from the
	/// Keychain here, at request time, and dropped after the call returns.
	func executor(for recipe: Recipe) throws -> RecipeExecuting {
		switch modeProvider() {
		case .local:
			return LocalLLMExecutor()
		case .byok:
			let provider = Self.provider(for: recipe)
			guard let key = try keyStore.load(provider: provider), !key.isEmpty else {
				throw RecipeRouterError.missingProviderKey(provider)
			}
			return LocalLLMExecutor(
				serverURLProvider: { Self.baseURL(for: provider) },
				defaultModelProvider: { WhisperaSettings.byokModel },
				apiKeyProvider: { key })
		}
	}

	static func provider(for recipe: Recipe) -> ProviderId {
		let raw = recipe.steps.first?.config.provider?.lowercased()
		return raw == "claude" || raw == "anthropic" ? .anthropic : .openai
	}

	/// BYOK talks to the provider directly, so the key never reaches any server
	/// but the user's own provider. Anthropic is reached through its
	/// OpenAI-compatible `chat/completions` endpoint.
	///
	/// `nonisolated` because the executor's URL provider is `@Sendable` and so
	/// cannot inherit this type's main-actor isolation; the lookup is pure.
	nonisolated static func baseURL(for provider: ProviderId) -> URL? {
		switch provider {
		case .openai: return URL(string: "https://api.openai.com/v1")
		case .anthropic: return URL(string: "https://api.anthropic.com/v1")
		}
	}
}
