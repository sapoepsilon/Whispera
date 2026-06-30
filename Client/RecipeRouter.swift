// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where recipe LLM steps run. Mutually exclusive at the app-global level. WHI-39.
enum LLMMode: String, CaseIterable, Sendable {
	case local
	case subscription
	case byok

	var displayName: String {
		switch self {
		case .local: return "Local"
		case .subscription: return "Subscription"
		case .byok: return "Bring Your Own Key"
		}
	}
}

extension WhisperaSettings {
	private static let llmModeKey = "whisperaLLMMode"

	static var llmMode: LLMMode {
		get { LLMMode(rawValue: UserDefaults.standard.string(forKey: llmModeKey) ?? "") ?? .local }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: llmModeKey) }
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

/// Runs a recipe through the backend execute endpoint. Used for both
/// Subscription (Bearer only) and BYOK (Bearer + X-Provider-Key) modes.
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
		case .subscription:
			guard auth.isSignedIn else { throw RecipeRouterError.notSignedIn }
			return BackendExecutor(providerKey: nil)
		case .byok:
			// BYOK still routes through the backend execute endpoint (pass-through),
			// which requires Bearer auth — the user's key just replaces platform
			// credits via X-Provider-Key. So a signed-in account is still needed.
			guard auth.isSignedIn else { throw RecipeRouterError.notSignedIn }
			let provider = Self.provider(for: recipe)
			guard let key = try keyStore.load(provider: provider), !key.isEmpty else {
				throw RecipeRouterError.missingProviderKey(provider)
			}
			return BackendExecutor(providerKey: key)
		}
	}

	static func provider(for recipe: Recipe) -> ProviderId {
		let raw = recipe.steps.first?.config.provider?.lowercased()
		return raw == "claude" || raw == "anthropic" ? .anthropic : .openai
	}
}
