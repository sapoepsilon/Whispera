// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaOpenAI
import WhisperaRecipes

/// Builds the executor a recipe runs on. App glue only: the pipeline, the
/// interpolation and the HTTP client all live in `WhisperaRecipes` /
/// `WhisperaOpenAI` now.
///
/// There is no mode left to resolve. `LLMMode {local, byok}` used to switch
/// between two arms that both returned `LocalLLMExecutor`, differing only in
/// base URL and Keychain account — presentation, not architecture (WHI-91).
/// What remains is reading the configured LLM server and pointing the package's
/// pipeline at it.
enum RecipeRouterError: LocalizedError, Equatable {
	case noServerConfigured

	var errorDescription: String? {
		switch self {
		case .noServerConfigured:
			return "No LLM server configured — add one under Settings → Servers."
		}
	}
}

@MainActor
struct RecipeRouter {
	static let shared = RecipeRouter()

	private let entryProvider: () -> ServerEntry

	init(entryProvider: @escaping () -> ServerEntry = { WhisperaSettings.llmServer }) {
		self.entryProvider = entryProvider
	}

	func run(recipe: Recipe, input: String) async throws -> String {
		try await executor().run(recipe: recipe, input: input)
	}

	/// The pipeline for the configured server. The key is read from the Keychain
	/// at request time by the provider closure and never held here.
	func executor() throws -> RecipeExecuting {
		let entry = entryProvider()
		guard let url = entry.url else { throw RecipeRouterError.noServerConfigured }
		return RecipePipeline.openAI(
			client: Self.client(for: entry, url: url),
			defaultModel: { entry.model })
	}

	/// Also used by the Settings "Test" button, which needs the same client the
	/// recipes will run on rather than an approximation of it.
	static func client(for entry: ServerEntry, url: URL) -> OpenAICompatibleClient {
		OpenAICompatibleClient(
			baseURL: url,
			apiKeyProvider: entry.keyProvider,
			logger: .whispera)
	}
}

extension OpenAILogger {
	/// The package redacts before emitting; this only chooses where the line
	/// goes. Nothing reaches `AppLogger` unredacted — WHI-93's leak was the app
	/// logging `server.absoluteString` verbatim on a URL that may carry a key.
	static let whispera = OpenAILogger { level, message in
		switch level {
		case .info: AppLogger.shared.network.info("\(message)")
		case .error: AppLogger.shared.network.error("\(message)")
		}
	}
}
