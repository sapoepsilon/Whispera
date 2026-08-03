// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

/// Unregisters its observer when it is released. An actor-isolated class cannot
/// read its own stored properties from `deinit`, so the teardown lives in an
/// object whose lifetime already matches the observer's.
private final class ObserverToken {
	private let token: NSObjectProtocol

	init(_ token: NSObjectProtocol) {
		self.token = token
	}

	deinit {
		NotificationCenter.default.removeObserver(token)
	}
}

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
	private let mediaAlertDelaySeconds: Double
	private let defaultCommandId: () -> String
	private var currentTask: Task<String?, Never>?
	private var clearErrorTask: Task<Void, Never>?
	/// A browser Whispera could not pause, held until the dictation that hit it is
	/// over: a modal mid-recording would take the focus the dictation is aimed at.
	/// Stays pending until it is actually shown, so a run where the alert could not
	/// be put up doesn't consume the one announcement we get per browser.
	private var pendingMediaNotice: String?
	private var mediaAlertTask: Task<Void, Never>?
	private var blockedMediaObserver: ObserverToken?

	init(
		store: RecipeStore = .shared,
		errorDisplaySeconds: Double = 3,
		mediaAlertDelaySeconds: Double = 0.6,
		defaultCommandId: @escaping () -> String = { WhisperaSettings.defaultCommandId },
		run: @escaping (Recipe, String) async throws -> String = { recipe, input in
			try await RecipeRouter.shared.run(recipe: recipe, input: input)
		}
	) {
		self.store = store
		self.errorDisplaySeconds = errorDisplaySeconds
		self.mediaAlertDelaySeconds = mediaAlertDelaySeconds
		self.defaultCommandId = defaultCommandId
		self.run = run
		observeBlockedMedia()
	}

	/// MediaPlaybackCoordinator only posts once per browser per app run, so this
	/// is the whole in-run throttle; "Don't Show Again" is the permanent one.
	private func observeBlockedMedia() {
		let token = NotificationCenter.default.addObserver(
			forName: .browserMediaPauseBlocked,
			object: nil,
			queue: .main
		) { [weak self] notification in
			let message = notification.userInfo?[MediaPlaybackCoordinator.blockedMessageKey] as? String
			Task { @MainActor in
				guard let message, !message.isEmpty else { return }
				guard !BlockedBrowserMediaAlert.isSuppressed else { return }
				self?.pendingMediaNotice = message
			}
		}
		blockedMediaObserver = ObserverToken(token)
	}

	/// The configured default command, if it still exists in the store. Runs on
	/// every dictation that doesn't match a trigger phrase. See WHI-49.
	private func defaultCommand() -> Recipe? {
		let id = defaultCommandId()
		guard !id.isEmpty else { return nil }
		return store.recipes.first { $0.id == id }
	}

	/// Returns the text to paste, or `nil` if nothing should be pasted (recipe
	/// produced an empty result). A new call cancels any in-flight recipe.
	func process(_ transcription: String) async -> String? {
		// Runs after every other exit path, including the empty-dictation and
		// no-recipe returns: the pause failure belongs to the recording that just
		// ended, not to whatever the recipe engine did or didn't do.
		defer { flushBlockedMediaNotice() }
		currentTask?.cancel()

		// Empty/whitespace dictation: do nothing — never spend a model call.
		guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return nil
		}

		// Trigger phrase wins; otherwise fall back to the default command; if
		// neither applies, paste the raw transcription unchanged.
		let recipe: Recipe
		let input: String
		if let match = RecipeMatcher.match(text: transcription, recipes: store.recipes) {
			recipe = match.recipe
			input = match.remainder
		} else if let fallback = defaultCommand() {
			recipe = fallback
			input = transcription
		} else {
			return transcription
		}

		lastError = nil
		overlayError = nil
		clearErrorTask?.cancel()
		isRunning = true
		runningRecipeName = recipe.name
		defer {
			isRunning = false
			runningRecipeName = nil
		}

		let task = Task { () -> String? in
			do {
				let output = try await run(recipe, input)
				if Task.isCancelled { return nil }
				guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
					self.flashError("“\(recipe.name)” returned nothing.")
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

	/// Explains the browser we could not pause, now that the dictation it belongs
	/// to is over.
	///
	/// The wait matters: AudioManager pastes the dictation immediately after
	/// `process` returns, by posting a ⌘V the focused app has not handled yet.
	/// Activating Whispera for the modal before that lands would take the
	/// keystroke's target away and drop the user's words.
	private func flushBlockedMediaNotice() {
		guard let message = pendingMediaNotice else { return }
		let seconds = mediaAlertDelaySeconds
		mediaAlertTask?.cancel()
		mediaAlertTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			guard !Task.isCancelled else { return }
			AppLogger.shared.audioManager.info("Showing the blocked browser media permission alert")
			if BlockedBrowserMediaAlert.present(message: message) {
				self?.pendingMediaNotice = nil
			}
		}
	}
}
