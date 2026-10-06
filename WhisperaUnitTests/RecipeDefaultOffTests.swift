// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaRecipes

@testable import Whispera

/// Recipes send dictation to an LLM server, so none runs until the user turns
/// recipes on, and a run that fails pastes the raw words without a HUD message
/// — the reason waits in Settings until the next run succeeds.
@MainActor
struct RecipeDefaultOffTests {
	private struct ServerError: LocalizedError {
		let errorDescription: String?
	}

	private final class Calls {
		var count = 0
		var fail = true
	}

	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "RecipeDefaultOffTests-\(UUID().uuidString)")!
	}

	private func makeStore(_ recipes: [Recipe] = []) async -> Whispera.RecipeStore {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("recipes-\(UUID().uuidString).json")
		let store = Whispera.RecipeStore(fileURL: url)
		for recipe in recipes { await store.create(recipe) }
		return store
	}

	private func userRecipe(name: String = "iMessage", trigger: String? = nil) -> Recipe {
		Recipe(
			name: name, triggerPhrase: trigger,
			steps: [RecipeStep(config: LLMStepConfig(prompt: "Make this an iMessage: {{input}}"))])
	}

	// MARK: - Default state

	@Test func aFreshInstallHasRecipesOff() {
		let defaults = makeDefaults()
		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: [])
		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey) == false)
		#expect(defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) ?? "" == "")
	}

	@Test func theStarterSetDoesNotRunWhileRecipesAreOff() async {
		let store = await makeStore()
		await store.loadDefaults()
		let calls = Calls()
		let starterId = store.recipes[0].id
		let coordinator = DictationCoordinator(
			store: store, health: RecipeRunHealth(defaults: makeDefaults()),
			isEnabled: { false }, defaultCommandId: { starterId }
		) { _, _ in
			calls.count += 1
			return "rewritten"
		}

		#expect(await coordinator.process("summarize the meeting notes") == "summarize the meeting notes")
		#expect(await coordinator.process("hello there") == "hello there")
		#expect(calls.count == 0)
	}

	@Test func pickingADefaultCommandIsTheOptIn() {
		let defaults = makeDefaults()
		WhisperaSettings.didPickDefaultCommand("", in: defaults)
		#expect(defaults.object(forKey: WhisperaSettings.recipesEnabledKey) == nil)
		WhisperaSettings.didPickDefaultCommand("some-id", in: defaults)
		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
	}

	// MARK: - Migration

	@Test func anUntouchedStarterSetWithItsRecipeAsDefaultMigratesOff() {
		let defaults = makeDefaults()
		let starters = Recipe.localDefaults
		defaults.set(starters[2].id, forKey: WhisperaSettings.defaultCommandIdKey)

		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: starters)

		#expect(defaults.object(forKey: WhisperaSettings.recipesEnabledKey) as? Bool == false)
		#expect(defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) == "")
	}

	@Test func aRecipeTheUserWroteButNeverWiredUpMigratesOff() {
		let defaults = makeDefaults()
		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: [userRecipe()])
		#expect(defaults.object(forKey: WhisperaSettings.recipesEnabledKey) as? Bool == false)
	}

	@Test func aUserRecipeChosenAsDefaultMigratesOn() {
		let defaults = makeDefaults()
		let mine = userRecipe()
		defaults.set(mine.id, forKey: WhisperaSettings.defaultCommandIdKey)

		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: Recipe.localDefaults + [mine])

		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
		#expect(defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) == mine.id)
	}

	@Test func anEditedStarterRecipeWithATriggerMigratesOn() {
		let defaults = makeDefaults()
		var edited = Recipe.localDefaults[0]
		edited.steps[0].config.prompt = "Make it sound like me: {{input}}"

		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: [edited])

		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
	}

	@Test func theMigrationRunsOnceAndNeverOverridesTheUser() {
		let defaults = makeDefaults()
		defaults.set(false, forKey: WhisperaSettings.recipesEnabledKey)
		let mine = userRecipe(trigger: "imessage")
		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: [mine])
		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey) == false)

		defaults.set(true, forKey: WhisperaSettings.recipesEnabledKey)
		RecipeEnablementMigration.migrateIfNeeded(in: defaults, recipes: [])
		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
	}

	// MARK: - Failure falls back quietly

	@Test(arguments: [
		"Model server error (HTTP 503): Service Unavailable",
		"Model server error (HTTP 401): invalid api key",
		"Couldn't reach the model server at http://localhost:8317/v1 — the connection was refused.",
	])
	func aFailingRecipePastesTheRawTranscriptAndRecordsWhy(reason: String) async {
		let mine = userRecipe()
		let store = await makeStore([mine])
		let health = RecipeRunHealth(defaults: makeDefaults())
		let noticesBefore = AppNoticeCenter.shared.notices.map(\.id)
		let coordinator = DictationCoordinator(
			store: store, health: health, isEnabled: { true }, defaultCommandId: { mine.id }
		) { _, _ in throw ServerError(errorDescription: reason) }

		let pasted = await coordinator.process("see you at seven")

		#expect(pasted == "see you at seven")
		#expect(health.lastFailure?.recipeName == "iMessage")
		#expect(health.lastFailure?.reason == reason)
		#expect(!coordinator.isRunning)
		#expect(AppNoticeCenter.shared.notices.map(\.id) == noticesBefore)
	}

	@Test func aTimeoutAlsoFallsBackToTheRawTranscript() async {
		let mine = userRecipe()
		let store = await makeStore([mine])
		let health = RecipeRunHealth(defaults: makeDefaults())
		let coordinator = DictationCoordinator(
			store: store, health: health, isEnabled: { true }, defaultCommandId: { mine.id }
		) { _, _ in throw URLError(.timedOut) }

		#expect(await coordinator.process("running late") == "running late")
		#expect(health.lastFailure != nil)
	}

	@Test func anEmptyAnswerPastesTheRawTranscript() async {
		let mine = userRecipe()
		let store = await makeStore([mine])
		let health = RecipeRunHealth(defaults: makeDefaults())
		let coordinator = DictationCoordinator(
			store: store, health: health, isEnabled: { true }, defaultCommandId: { mine.id }
		) { _, _ in "  \n" }

		#expect(await coordinator.process("on my way") == "on my way")
		#expect(health.lastFailure?.reason == "The model returned an empty response.")
	}

	@Test func aSuccessfulRunClearsTheRecordedFailure() async {
		let mine = userRecipe()
		let store = await makeStore([mine])
		let defaults = makeDefaults()
		let health = RecipeRunHealth(defaults: defaults)
		let calls = Calls()
		let coordinator = DictationCoordinator(
			store: store, health: health, isEnabled: { true }, defaultCommandId: { mine.id }
		) { _, input in
			if calls.fail { throw ServerError(errorDescription: "Model server error (HTTP 503)") }
			return "\(input) 👋"
		}

		_ = await coordinator.process("hi")
		#expect(health.lastFailure != nil)
		#expect(RecipeRunHealth(defaults: defaults).lastFailure != nil)

		calls.fail = false
		#expect(await coordinator.process("hi") == "hi 👋")
		#expect(health.lastFailure == nil)
		#expect(RecipeRunHealth(defaults: defaults).lastFailure == nil)
	}

	@Test func theStoredReasonIsOneRedactedLine() {
		let health = RecipeRunHealth(defaults: makeDefaults())
		health.recordFailure(
			recipeName: "iMessage",
			reason: "Couldn't reach http://x/v1?api_key=sk-abcdefghijklmnopqrstuvwxyz123456\n<html>\n"
				+ String(repeating: "x", count: 500))

		let reason = health.lastFailure?.reason ?? ""
		#expect(!reason.contains("\n"))
		#expect(!reason.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
		#expect(reason.count <= RecipeRunHealth.maxReasonLength)
	}
}
