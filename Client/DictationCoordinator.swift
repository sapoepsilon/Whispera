// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI
import WhisperaOpenAI

/// Glue between transcription and the recipe engine. Given transcribed text, it
/// runs the matching recipe (if any) and returns what should be pasted. With
/// recipes switched off, or no match, the raw transcription is returned
/// unchanged. See WHI-41.
@MainActor
@Observable
final class DictationCoordinator {
	static let shared = DictationCoordinator()

	private(set) var isRunning = false
	private(set) var runningRecipeName: String?

	private let store: RecipeStore
	private let health: RecipeRunHealth
	private let run: (Recipe, String) async throws -> String
	private let isEnabled: () -> Bool
	private let defaultCommandId: () -> String
	private var currentTask: Task<String?, Never>?

	init(
		store: RecipeStore = .shared,
		health: RecipeRunHealth = .shared,
		isEnabled: @escaping () -> Bool = { WhisperaSettings.recipesEnabled },
		defaultCommandId: @escaping () -> String = { WhisperaSettings.defaultCommandId },
		run: @escaping (Recipe, String) async throws -> String = { recipe, input in
			try await RecipeRouter.shared.run(recipe: recipe, input: input)
		}
	) {
		self.store = store
		self.health = health
		self.isEnabled = isEnabled
		self.defaultCommandId = defaultCommandId
		self.run = run
	}

	/// The configured default command, if it still exists in the store. Runs on
	/// every dictation that doesn't match a trigger phrase. See WHI-49.
	private func defaultCommand() -> Recipe? {
		let id = defaultCommandId()
		guard !id.isEmpty else { return nil }
		return store.recipes.first { $0.id == id }
	}

	/// The recipe this dictation should run, if any. Nothing runs unless the
	/// user switched recipes on; then a trigger phrase wins over the default.
	private func selectRecipe(for transcription: String) -> (recipe: Recipe, input: String)? {
		guard isEnabled() else { return nil }
		if let match = RecipeMatcher.match(text: transcription, recipes: store.recipes) {
			return (match.recipe, match.remainder)
		}
		return defaultCommand().map { ($0, transcription) }
	}

	/// Returns the text to paste, or `nil` if nothing should be pasted (empty
	/// dictation, or a superseded run). A new call cancels any in-flight recipe.
	///
	/// A recipe that fails — unreachable server, 401/403, 5xx, timeout, empty
	/// answer — pastes the raw transcription without a word on the HUD: a
	/// warning per dictation is noise the user can do nothing about mid-sentence.
	/// The reason goes to `RecipeRunHealth`, which Settings shows until the next
	/// run succeeds.
	func process(_ transcription: String) async -> String? {
		currentTask?.cancel()

		// Empty/whitespace dictation: do nothing — never spend a model call.
		guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return nil
		}

		guard let selected = selectRecipe(for: transcription) else { return transcription }
		let (recipe, input) = selected

		isRunning = true
		runningRecipeName = recipe.name
		defer {
			isRunning = false
			runningRecipeName = nil
		}

		let health = self.health
		let task = Task { () -> String? in
			do {
				let output = try await run(recipe, input)
				if Task.isCancelled { return nil }
				guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
					health.recordFailure(recipeName: recipe.name, reason: "The model returned an empty response.")
					return transcription
				}
				health.recordSuccess()
				return output
			} catch is CancellationError {
				return nil
			} catch {
				if Task.isCancelled { return nil }
				let reason = RecipeRunHealth.condense(
					(error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
				AppLogger.shared.network.error("Recipe \"\(recipe.name)\" failed, pasted the raw transcript: \(reason)")
				health.recordFailure(recipeName: recipe.name, reason: reason)
				return transcription
			}
		}
		currentTask = task
		return await task.value
	}

	func cancel() {
		currentTask?.cancel()
		isRunning = false
		runningRecipeName = nil
	}
}

/// The outcome of the last recipe run, for Settings → Recipes. Only a failure
/// is kept: it is shown there once ("used the raw transcript") and cleared by
/// the next run that succeeds. Persisted so a failure from a dictation is still
/// there when the user gets round to opening Settings after a relaunch.
@MainActor
@Observable
final class RecipeRunHealth {
	static let shared = RecipeRunHealth()

	struct Failure: Equatable {
		let recipeName: String
		let reason: String
		let date: Date
	}

	private(set) var lastFailure: Failure?

	@ObservationIgnored private let defaults: UserDefaults

	private enum Key {
		static let recipeName = "whisperaRecipeLastFailureRecipe"
		static let reason = "whisperaRecipeLastFailureReason"
		static let date = "whisperaRecipeLastFailureDate"
	}

	/// Long server bodies (an HTML 503 page) would swamp a settings row.
	static let maxReasonLength = 200

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		if let reason = defaults.string(forKey: Key.reason) {
			lastFailure = Failure(
				recipeName: defaults.string(forKey: Key.recipeName) ?? "",
				reason: reason,
				date: defaults.object(forKey: Key.date) as? Date ?? Date())
		}
	}

	func recordFailure(recipeName: String, reason: String, at date: Date = Date()) {
		let failure = Failure(recipeName: recipeName, reason: Self.condense(reason), date: date)
		lastFailure = failure
		defaults.set(failure.recipeName, forKey: Key.recipeName)
		defaults.set(failure.reason, forKey: Key.reason)
		defaults.set(failure.date, forKey: Key.date)
	}

	func recordSuccess() {
		guard lastFailure != nil else { return }
		clear()
	}

	func clear() {
		lastFailure = nil
		defaults.removeObject(forKey: Key.recipeName)
		defaults.removeObject(forKey: Key.reason)
		defaults.removeObject(forKey: Key.date)
	}

	/// One line, capped and redacted: the row is a pointer to the problem, not
	/// a log viewer, and an unreachable-server reason quotes the base URL, which
	/// may carry a key in its query.
	static func condense(_ reason: String) -> String {
		let oneLine = OpenAIRedactor.redactSecrets(reason).split(whereSeparator: \.isNewline)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
		guard oneLine.count > maxReasonLength else { return oneLine }
		return String(oneLine.prefix(maxReasonLength - 1)) + "…"
	}
}
