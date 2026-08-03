// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

/// Single source of truth for the user's recipes ("Commands").
///
/// Recipes persist to a local JSON cache so the trigger matcher and Local mode
/// work offline. The shipping app has no account, so that cache is the only
/// path — the backend CRUD below stays parked behind `usesBackend`. See
/// WHI-30 / WHI-41.
@MainActor
@Observable
final class RecipeStore {
	static let shared = RecipeStore()

	private(set) var recipes: [Recipe] = []
	private(set) var isSyncing = false
	var lastError: String?

	private let api: WhisperaAPIClient
	private let auth: AuthManager
	private let fileURL: URL

	init(
		api: WhisperaAPIClient = .shared,
		auth: AuthManager = .shared,
		fileURL: URL? = nil
	) {
		self.api = api
		self.auth = auth
		self.fileURL = fileURL ?? Self.defaultFileURL()
		load()
	}

	/// Hard-off while the app ships without accounts: every branch below stays on
	/// the local cache and no `api` call is ever made. Flip back to
	/// `auth.isSignedIn` to restore backend sync.
	private var usesBackend: Bool { false }

	// MARK: - Local persistence

	private static func defaultFileURL() -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera", isDirectory: true)
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		return base.appendingPathComponent("recipes.json")
	}

	private func load() {
		guard let data = try? Data(contentsOf: fileURL),
			let decoded = try? JSONDecoder().decode([Recipe].self, from: data)
		else { return }
		recipes = decoded
	}

	private func persist() {
		guard let data = try? JSONEncoder().encode(recipes) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}

	// MARK: - Sync

	/// Pulls recipes from the backend when signed in and replaces the cache.
	func sync() async {
		guard usesBackend else { return }
		isSyncing = true
		lastError = nil
		defer { isSyncing = false }
		do {
			recipes = try await api.listRecipes()
			persist()
		} catch {
			lastError = message(error)
		}
	}

	// MARK: - CRUD

	func create(_ recipe: Recipe) async {
		lastError = nil
		do {
			if usesBackend {
				let created = try await api.createRecipe(RecipeInput(from: recipe))
				recipes.append(created)
			} else {
				recipes.append(recipe)
			}
			persist()
		} catch {
			lastError = message(error)
		}
	}

	func update(_ recipe: Recipe) async {
		lastError = nil
		do {
			let result: Recipe
			if usesBackend {
				result = try await api.updateRecipe(id: recipe.id, RecipeInput(from: recipe))
			} else {
				result = recipe
			}
			if let idx = recipes.firstIndex(where: { $0.id == recipe.id }) {
				recipes[idx] = result
			}
			persist()
		} catch {
			lastError = message(error)
		}
	}

	func delete(_ recipe: Recipe) async {
		lastError = nil
		do {
			if usesBackend {
				try await api.deleteRecipe(id: recipe.id)
			}
			recipes.removeAll { $0.id == recipe.id }
			persist()
		} catch {
			lastError = message(error)
		}
	}

	/// Loads starter recipes: server seed when signed in, bundled defaults locally.
	func loadDefaults() async {
		if usesBackend {
			do {
				_ = try await api.seedDefaultRecipes()
				await sync()
			} catch {
				lastError = message(error)
			}
		} else if recipes.isEmpty {
			recipes = Recipe.localDefaults
			persist()
		}
	}

	private func message(_ error: Error) -> String {
		(error as? LocalizedError)?.errorDescription ?? error.localizedDescription
	}
}

extension Recipe {
	/// Bundled starter set for Local mode, mirroring the backend seed (WHI-46).
	static var localDefaults: [Recipe] {
		[
			Recipe(
				name: "Make professional", triggerPhrase: "make professional",
				steps: [
					llmStep(
						"Rewrite this in a polite, professional tone. Output only the rewritten message, no preamble.\n\n{{input}}"
					)
				]),
			Recipe(
				name: "Fix grammar", triggerPhrase: "fix grammar",
				steps: [
					llmStep(
						"Fix any grammar and punctuation issues in this text. Preserve meaning and tone. Output only the corrected text.\n\n{{input}}"
					)
				]),
			Recipe(
				name: "Summarize", triggerPhrase: "summarize",
				steps: [llmStep("Summarize this in one sentence. Output only the summary.\n\n{{input}}")]),
			Recipe(
				name: "Bullet points", triggerPhrase: "bullet points",
				steps: [
					llmStep(
						"Convert this text into a clean list of bullet points (one per line, each starting with \"- \"). Output only the bullets.\n\n{{input}}"
					)
				]),
		]
	}

	private static func llmStep(_ prompt: String) -> RecipeStep {
		RecipeStep(name: "llm", config: LLMStepConfig(prompt: prompt))
	}
}
