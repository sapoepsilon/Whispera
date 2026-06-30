// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

/// Glue between transcription and the recipe engine. Given transcribed text, it
/// runs the matching recipe (if any) and returns what should be pasted. With no
/// match, the raw transcription is returned unchanged. See WHI-41.
@MainActor
@Observable
final class DictationCoordinator {
	static let shared = DictationCoordinator()

	private(set) var isRunning = false
	private(set) var runningRecipeName: String?
	var lastError: String?
	/// Short-lived message for the dictation overlay; auto-clears so the HUD
	/// doesn't linger after a failed/empty recipe run.
	private(set) var overlayError: String?

	private let store: RecipeStore
	private let run: (Recipe, String) async throws -> String
	private let errorDisplaySeconds: Double
	private var currentTask: Task<String?, Never>?
	private var clearErrorTask: Task<Void, Never>?

	init(
		store: RecipeStore = .shared,
		errorDisplaySeconds: Double = 3,
		run: @escaping (Recipe, String) async throws -> String = { recipe, input in
			try await RecipeRouter.shared.run(recipe: recipe, input: input)
		}
	) {
		self.store = store
		self.errorDisplaySeconds = errorDisplaySeconds
		self.run = run
	}

	/// Returns the text to paste, or `nil` if nothing should be pasted (recipe
	/// produced an empty result). A new call cancels any in-flight recipe.
	func process(_ transcription: String) async -> String? {
		currentTask?.cancel()

		guard let match = RecipeMatcher.match(text: transcription, recipes: store.recipes) else {
			return transcription
		}

		lastError = nil
		overlayError = nil
		clearErrorTask?.cancel()
		isRunning = true
		runningRecipeName = match.recipe.name
		defer {
			isRunning = false
			runningRecipeName = nil
		}

		let task = Task { () -> String? in
			do {
				let output = try await run(match.recipe, match.remainder)
				if Task.isCancelled { return nil }
				guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
					self.flashError("“\(match.recipe.name)” returned nothing.")
					return nil
				}
				return output
			} catch is CancellationError {
				return nil
			} catch {
				// Don't lose the user's words: fall back to the raw transcription
				// and surface why the recipe didn't run.
				self.flashError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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

	/// Sets `lastError` and a self-clearing `overlayError` for the HUD.
	private func flashError(_ message: String) {
		lastError = message
		overlayError = message
		clearErrorTask?.cancel()
		let seconds = errorDisplaySeconds
		clearErrorTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			guard !Task.isCancelled else { return }
			self?.overlayError = nil
		}
	}
}
