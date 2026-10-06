// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation
import Testing
import WhisperaOpenAI
import WhisperaRecipes

@testable import Whispera

private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
	let suite = "CleanUpRecipeTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	defaults.removePersistentDomain(forName: suite)
	return defaults
}

@MainActor
private func makeStore(_ recipes: [Recipe] = []) async -> Whispera.RecipeStore {
	let url = FileManager.default.temporaryDirectory
		.appendingPathComponent("recipes-\(UUID().uuidString).json")
	let store = Whispera.RecipeStore(fileURL: url)
	for recipe in recipes { await store.create(recipe) }
	return store
}

private func chatCompletion(_ content: String) -> MockHTTPServer.Response {
	.json([
		"id": "chatcmpl-test",
		"object": "chat.completion",
		"choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
	])
}

private func keyStore() -> OpenAIKeyStore {
	OpenAIKeyStore(service: "com.macwhisper.app.tests.cleanup.\(UUID().uuidString)")
}

private let keychainAvailable: Bool = {
	let store = keyStore()
	defer { try? store.delete(serverId: "probe") }
	return (try? store.save(serverId: "probe", key: "x")) != nil
}()

private func legacyPrompts(_ prompts: [(id: String, name: String, template: String)]) -> Data {
	let objects = prompts.map { ["id": $0.id, "name": $0.name, "template": $0.template] }
	return try! JSONSerialization.data(withJSONObject: objects)
}

// MARK: - Migration

@MainActor
@Suite(.serialized)
struct PostProcessingMigrationTests {
	typealias Legacy = PostProcessingMigration.LegacyKey
	let llm = ServerEntry.Capability.llm

	@Test func aFreshInstallGetsCleanUpSwitchedOff() async {
		let defaults = isolatedDefaults()
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		let cleanUp = store.recipes.first(where: CleanUpRecipe.isBuiltIn)
		#expect(cleanUp?.name == "Clean up")
		#expect(cleanUp?.steps.first?.config.prompt == CleanUpRecipe.defaultPrompt)
		#expect(cleanUp?.triggerPhrase == nil)
		#expect(store.recipes.count == 1)
		#expect(!defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
		#expect((defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) ?? "").isEmpty)
		#expect(!CleanUpSettings(defaults: defaults).isOnRequestEnabled)
		#expect((defaults.string(forKey: llm.urlKey) ?? "").isEmpty)
	}

	@Test func enabledOnEveryDictationBecomesTheDefaultCommand() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set(true, forKey: Legacy.applyToEveryDictation)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
		#expect(defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) == CleanUpRecipe.id)
		#expect(CleanUpSettings(defaults: defaults).isOnRequestEnabled)
	}

	@Test func enabledForTheShortcutOnlyKeepsEveryOtherDictationRaw() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set("⌃⌥C", forKey: CleanUpSettings.Key.shortcut)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(CleanUpSettings(defaults: defaults).isOnRequestEnabled)
		#expect(CleanUpSettings(defaults: defaults).shortcut == "⌃⌥C")
		#expect(!defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
		#expect((defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) ?? "").isEmpty)
	}

	@Test func disabledPostProcessingStaysOffButKeepsItsSettings() async {
		let defaults = isolatedDefaults()
		defaults.set(false, forKey: Legacy.enabled)
		defaults.set(true, forKey: Legacy.applyToEveryDictation)
		defaults.set("custom", forKey: Legacy.providerID)
		defaults.set(["custom": "http://192.168.1.20:11434/v1"], forKey: Legacy.baseURLs)
		defaults.set(["custom": "qwen3:4b"], forKey: Legacy.models)
		defaults.set(
			legacyPrompts([(id: "mine", name: "Mine", template: "Tidy: ${output}")]), forKey: Legacy.prompts)
		defaults.set("mine", forKey: Legacy.selectedPromptID)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(!defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
		#expect(!CleanUpSettings(defaults: defaults).isOnRequestEnabled)
		#expect(store.recipes.first(where: CleanUpRecipe.isBuiltIn)?.steps.first?.config.prompt == "Tidy: {{input}}")
		#expect(defaults.string(forKey: llm.urlKey) == "http://192.168.1.20:11434/v1")
		#expect(defaults.string(forKey: llm.modelKey) == "qwen3:4b")
	}

	@Test func theSelectedCustomPromptBecomesCleanUpAndTheOthersBecomeRecipes() async {
		let defaults = isolatedDefaults()
		defaults.set(
			legacyPrompts([
				(id: "default_cleanup", name: "Clean up transcript", template: "<t>${output}</t>"),
				(id: "email", name: "Email tone", template: "Make this an email."),
				(id: "notes", name: "Meeting notes", template: "Notes from: ${output}"),
			]), forKey: Legacy.prompts)
		defaults.set("email", forKey: Legacy.selectedPromptID)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		let cleanUp = store.recipes.first(where: CleanUpRecipe.isBuiltIn)
		#expect(cleanUp?.steps.first?.config.prompt == "Make this an email.\n\n{{input}}")
		let notes = store.recipes.first { $0.name == "Meeting notes" }
		#expect(notes?.steps.first?.config.prompt == "Notes from: {{input}}")
		#expect(notes?.triggerPhrase == nil)
		#expect(!store.recipes.contains { $0.name == "Clean up transcript" })
		#expect(store.recipes.count == 2)
	}

	@Test(.enabled(if: keychainAvailable, "Keychain not available"))
	func aHostedProviderMovesIntoAnEmptyLLMServerWithItsKey() async throws {
		let defaults = isolatedDefaults()
		let keys = keyStore()
		let legacyKeys = keyStore()
		defer {
			try? keys.delete(serverId: llm.keychainId)
			try? legacyKeys.delete(serverId: "groq")
		}
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set("groq", forKey: Legacy.providerID)
		defaults.set(["groq": "llama-3.3-70b-versatile"], forKey: Legacy.models)
		try legacyKeys.save(serverId: "groq", key: "gsk-test-key")
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keys, legacyKeyStore: legacyKeys)

		#expect(defaults.string(forKey: llm.urlKey) == "https://api.groq.com/openai/v1")
		#expect(defaults.string(forKey: llm.modelKey) == "llama-3.3-70b-versatile")
		#expect(try keys.load(serverId: llm.keychainId) == "gsk-test-key")
		#expect(try legacyKeys.load(serverId: "groq") == "gsk-test-key", "The old key stays where it was")
		#expect(store.recipes.first(where: CleanUpRecipe.isBuiltIn)?.steps.first?.config.model == nil)
	}

	@Test func anExistingLLMServerIsNeverOverwritten() async {
		let defaults = isolatedDefaults()
		defaults.set("http://localhost:8317/v1", forKey: llm.urlKey)
		defaults.set("gpt-5.4-mini", forKey: llm.modelKey)
		defaults.set("openai", forKey: Legacy.providerID)
		defaults.set(["openai": "gpt-4o-mini"], forKey: Legacy.models)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(defaults.string(forKey: llm.urlKey) == "http://localhost:8317/v1")
		#expect(defaults.string(forKey: llm.modelKey) == "gpt-5.4-mini")
		#expect(
			store.recipes.first(where: CleanUpRecipe.isBuiltIn)?.steps.first?.config.model == nil,
			"Another server's model would not exist on this one")
	}

	@Test func theSameServerWithAnotherModelPinsItOnCleanUp() async {
		let defaults = isolatedDefaults()
		defaults.set("http://localhost:11434", forKey: llm.urlKey)
		defaults.set("llama3.2", forKey: llm.modelKey)
		defaults.set("ollama", forKey: Legacy.providerID)
		defaults.set(["ollama": "qwen3:4b"], forKey: Legacy.models)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(defaults.string(forKey: llm.modelKey) == "llama3.2")
		#expect(store.recipes.first(where: CleanUpRecipe.isBuiltIn)?.steps.first?.config.model == "qwen3:4b")
	}

	@Test func appleIntelligenceLeavesTheServerAlone() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set("apple_intelligence", forKey: Legacy.providerID)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect((defaults.string(forKey: llm.urlKey) ?? "").isEmpty)
		#expect(CleanUpSettings(defaults: defaults).isOnRequestEnabled)
		#expect(store.recipes.contains(where: CleanUpRecipe.isBuiltIn))
	}

	@Test func aDefaultTheUserAlreadyPickedIsKept() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set(true, forKey: Legacy.applyToEveryDictation)
		defaults.set("their-recipe", forKey: WhisperaSettings.defaultCommandIdKey)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(defaults.string(forKey: WhisperaSettings.defaultCommandIdKey) == "their-recipe")
		#expect(defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
	}

	@Test func runningTwiceChangesNothing() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: Legacy.enabled)
		defaults.set(true, forKey: Legacy.applyToEveryDictation)
		defaults.set(
			legacyPrompts([
				(id: "a", name: "A", template: "A: ${output}"), (id: "b", name: "B", template: "B: ${output}"),
			]), forKey: Legacy.prompts)
		let store = await makeStore()
		let keys = keyStore()
		let legacyKeys = keyStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keys, legacyKeyStore: legacyKeys)
		let first = store.recipes
		#expect(first.count == 2)

		// The user turns it off and edits Clean up; a relaunch must not undo either.
		defaults.set(false, forKey: WhisperaSettings.recipesEnabledKey)
		guard var edited = first.first(where: CleanUpRecipe.isBuiltIn) else {
			Issue.record("Clean up was not created")
			return
		}
		edited.steps[0].config.prompt = "Edited {{input}}"
		await store.update(edited)

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keys, legacyKeyStore: legacyKeys)

		#expect(store.recipes.count == 2)
		#expect(store.recipes.first(where: CleanUpRecipe.isBuiltIn)?.steps.first?.config.prompt == "Edited {{input}}")
		#expect(!defaults.bool(forKey: WhisperaSettings.recipesEnabledKey))
	}

	@Test func aMissingCleanUpComesBackOnLaunch() async {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: PostProcessingMigration.migratedFlagKey)
		let store = await makeStore()

		await PostProcessingMigration.migrateIfNeeded(
			in: defaults, store: store, keyStore: keyStore(), legacyKeyStore: keyStore())

		#expect(store.recipes.map(\.id) == [CleanUpRecipe.id])
	}

	@Test func theStarterSetStillLoadsNextToCleanUp() async {
		let store = await makeStore([CleanUpRecipe.make()])
		await store.loadDefaults()
		#expect(store.recipes.count == 1 + Recipe.localDefaults.count)
		await store.loadDefaults()
		#expect(store.recipes.count == 1 + Recipe.localDefaults.count)
	}

	@Test func legacyPromptsConvertToTheRecipePlaceholder() {
		#expect(CleanUpRecipe.recipePrompt(fromLegacyTemplate: "Fix ${output} now") == "Fix {{input}} now")
		#expect(CleanUpRecipe.recipePrompt(fromLegacyTemplate: "  Be brief.\n") == "Be brief.\n\n{{input}}")
		#expect(CleanUpRecipe.recipePrompt(fromLegacyTemplate: "") == "{{input}}")
	}
}

// MARK: - Running Clean up

@MainActor
@Suite(.serialized)
struct CleanUpExecutionTests {
	private func coordinator(
		store: Whispera.RecipeStore, health: RecipeRunHealth, serverURL: String, recipesOn: Bool = false,
		defaultId: String = ""
	) -> DictationCoordinator {
		let router = RecipeRouter(entryProvider: {
			ServerEntry(capability: .llm, urlString: serverURL, model: "server-model")
		})
		return DictationCoordinator(
			store: store, health: health, isEnabled: { recipesOn }, defaultCommandId: { defaultId }
		) { recipe, input in
			try await router.run(recipe: recipe, input: input)
		}
	}

	@Test func cleanUpRunsThroughTheSharedClientAndPastesItsAnswer() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("<think>tidy it</think>\nMeet at 3:30 tomorrow.") }
		try await server.start()
		defer { server.stop() }
		let store = await makeStore([CleanUpRecipe.make()])
		let health = RecipeRunHealth(defaults: isolatedDefaults())
		let coordinator = coordinator(
			store: store, health: health, serverURL: server.baseURL, recipesOn: true, defaultId: CleanUpRecipe.id)

		let result = await coordinator.processDictation("um meet at three thirty tomorrow", cleanUp: false)

		#expect(result?.text == "Meet at 3:30 tomorrow.")
		#expect(result?.history?.processedText == "Meet at 3:30 tomorrow.")
		#expect(result?.history?.promptName == "Clean up")
		#expect(health.lastFailure == nil)
		let request = try #require(server.requests.first)
		#expect(request.method == "POST")
		#expect(request.path == "/v1/chat/completions")
		let body = try #require(request.jsonBody)
		#expect(body["model"] as? String == "server-model")
		let messages = try #require(body["messages"] as? [[String: String]])
		#expect(messages.count == 1)
		#expect(messages[0]["role"] == "user")
		#expect(messages[0]["content"]?.contains("<transcript>\num meet at three thirty tomorrow\n</transcript>") == true)
	}

	@Test func theShortcutRunsCleanUpWhileRecipesAreOff() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("Hello, world.") }
		try await server.start()
		defer { server.stop() }
		let pinned = CleanUpRecipe.make(model: "pinned-model")
		let store = await makeStore([pinned])
		let coordinator = coordinator(
			store: store, health: RecipeRunHealth(defaults: isolatedDefaults()), serverURL: server.baseURL)

		#expect(await coordinator.processDictation("hello world", cleanUp: false)?.text == "hello world")
		#expect(server.requests.isEmpty)

		#expect(await coordinator.processDictation("hello world", cleanUp: true)?.text == "Hello, world.")
		#expect(server.requests.first?.jsonBody?["model"] as? String == "pinned-model")
	}

	@Test func aServerErrorPastesTheRawTranscriptQuietly() async throws {
		let server = try MockHTTPServer { _ in .json(["error": ["message": "overloaded"]], status: 503) }
		try await server.start()
		defer { server.stop() }
		let store = await makeStore([CleanUpRecipe.make()])
		let health = RecipeRunHealth(defaults: isolatedDefaults())
		let noticesBefore = AppNoticeCenter.shared.notices.map(\.id)
		let coordinator = coordinator(store: store, health: health, serverURL: server.baseURL)

		let result = await coordinator.processDictation("raw words here", cleanUp: true)

		#expect(result?.text == "raw words here")
		#expect(result?.history?.processedText == nil)
		#expect(result?.history?.errorMessage?.isEmpty == false)
		#expect(health.lastFailure?.recipeName == "Clean up")
		#expect(health.lastFailure?.reason.contains("503") == true)
		#expect(AppNoticeCenter.shared.notices.map(\.id) == noticesBefore)
	}

	@Test func aServerThatIsOffPastesTheRawTranscriptAndIsReportedOnce() async throws {
		let probe = try MockHTTPServer { _ in chatCompletion("unused") }
		try await probe.start()
		let deadURL = probe.baseURL
		probe.stop()
		let defaults = isolatedDefaults()
		let store = await makeStore([CleanUpRecipe.make()])
		let health = RecipeRunHealth(defaults: defaults)
		let coordinator = coordinator(store: store, health: health, serverURL: deadURL)

		let first = await coordinator.processDictation("first dictation", cleanUp: true)
		let second = await coordinator.processDictation("second dictation", cleanUp: true)

		#expect(first?.text == "first dictation")
		#expect(second?.text == "second dictation")
		let failure = try #require(health.lastFailure)
		#expect(failure.recipeName == "Clean up")
		let stored = RecipeRunHealth(defaults: defaults).lastFailure
		#expect(stored?.recipeName == failure.recipeName, "One stored failure, not one per dictation")
		#expect(stored?.reason == failure.reason)
	}

	@Test func noLLMServerFallsBackToTheRawTranscript() async {
		let store = await makeStore([CleanUpRecipe.make()])
		let health = RecipeRunHealth(defaults: isolatedDefaults())
		let coordinator = coordinator(store: store, health: health, serverURL: "")

		#expect(await coordinator.processDictation("plain words", cleanUp: true)?.text == "plain words")
		#expect(health.lastFailure?.reason == RecipeRouterError.noServerConfigured.errorDescription)
	}

	@Test func historyReprocessUsesCleanUp() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("Again.") }
		try await server.start()
		defer { server.stop() }
		let store = await makeStore([CleanUpRecipe.make()])
		let coordinator = coordinator(
			store: store, health: RecipeRunHealth(defaults: isolatedDefaults()), serverURL: server.baseURL)

		let record = await coordinator.cleanUpForHistory("again")
		#expect(record.processedText == "Again.")
		#expect(record.promptName == "Clean up")
		#expect(record.promptTemplate == CleanUpRecipe.defaultPrompt)
	}
}

// MARK: - Output and shortcut

struct RecipeOutputTextTests {
	@Test func stripsLeadingThinkBlock() {
		let raw = "  <think>\nthe user said um, I should drop it\n</think>\n\nMeet at 3:30 tomorrow."
		#expect(RecipeOutputText.stripLeadingThinkBlock(raw) == "Meet at 3:30 tomorrow.")
	}

	@Test func keepsTextWithoutThinkBlock() {
		#expect(RecipeOutputText.stripLeadingThinkBlock("Hello <think>x</think>") == "Hello <think>x</think>")
	}

	@Test func keepsUnterminatedThinkBlock() {
		#expect(RecipeOutputText.stripLeadingThinkBlock("<think>never closed") == "<think>never closed")
	}

	@Test func removesZeroWidthCharacters() {
		#expect(RecipeOutputText.stripInvisibleCharacters("Hi\u{200B} there\u{FEFF}\u{200C}\u{200D}") == "Hi there")
	}

	@Test func cleanTrims() {
		#expect(RecipeOutputText.clean("<think>a</think>  Done.\n") == "Done.")
	}
}

struct CleanUpShortcutTests {
	@Test func formatsModifiersInParserOrder() {
		#expect(ShortcutDisplayFormatter.format(modifiers: [.option, .shift], key: "Space") == "⌥⇧Space")
		#expect(ShortcutDisplayFormatter.format(modifiers: [.command, .control], key: "P") == "⌘⌃P")
	}

	@Test func rejectsModifierOnlyOrEmptyShortcut() {
		#expect(!CleanUpShortcutMonitor.isUsableShortcut(""))
		#expect(!CleanUpShortcutMonitor.isUsableShortcut("⌥⇧"))
		#expect(CleanUpShortcutMonitor.isUsableShortcut("⌥⇧Space"))
	}

	@Test func unknownKeysAreRejectedInsteadOfBecomingR() {
		#expect(ShortcutCombo("⌥⇧\u{E000}") == nil)
		#expect(ShortcutCombo("⌥⇧Å") == nil)
		#expect(!CleanUpShortcutMonitor.isUsableShortcut("⌥⇧\u{E000}"))
		// AppKit's F5 character is what older recorders stored for F5, so it reads as F5, not R
		#expect(ShortcutCombo("⌥⇧\u{F708}") == ShortcutCombo(modifiers: [.option, .shift], keyCode: 96))
		#expect(ShortcutCombo("⌥⌘R") == ShortcutCombo(modifiers: [.option, .command], keyCode: 15))
	}

	@Test func recorderNamesThePhysicalKey() {
		#expect(ShortcutDisplayFormatter.format(keyCode: 18, modifiers: [.option, .shift]) == "⌥⇧1")
		#expect(ShortcutDisplayFormatter.format(keyCode: 96, modifiers: [.control]) == "⌃F5")
		#expect(ShortcutDisplayFormatter.format(keyCode: 49, modifiers: [.option, .shift]) == "⌥⇧Space")
		#expect(ShortcutDisplayFormatter.format(keyCode: 15, modifiers: []) == nil)
		#expect(ShortcutDisplayFormatter.format(keyCode: 255, modifiers: [.command]) == nil)
	}

	@Test func everyNamedKeyRoundTripsToItsKeyCode() {
		for keyCode in UInt16(0)...UInt16(200) {
			guard let formatted = ShortcutDisplayFormatter.format(keyCode: keyCode, modifiers: [.command])
			else { continue }
			#expect(ShortcutCombo(formatted) == ShortcutCombo(modifiers: [.command], keyCode: keyCode), "\(formatted)")
		}
	}

	@Test func legacyShiftedSymbolsResolveToTheirKey() {
		#expect(ShortcutCombo("⌥⇧!") == ShortcutCombo(modifiers: [.option, .shift], keyCode: 18))
		#expect(ShortcutCombo("⌘?") == ShortcutCombo(modifiers: [.command], keyCode: 44))
	}

	@Test func conflictsWithTheOtherWhisperaShortcutsAreFound() {
		let defaults = isolatedDefaults()
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌘⌥R", defaults: defaults) == "⌥⌘R")
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌃F", defaults: defaults) == "⌃F")
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌥⇧Space", defaults: defaults) == nil)

		defaults.set("⌃⇧D", forKey: "globalShortcut")
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⇧⌃D", defaults: defaults) == "⌃⇧D")
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌥⌘R", defaults: defaults) == nil)

		RecordingControlSettings(defaults: defaults).cancelShortcut = CancelShortcutBinding(
			keyCode: 2, modifiers: [.command, .shift], display: "⌘⇧D")
		#expect(CleanUpShortcutMonitor.conflictingShortcut(for: "⌘⇧D", defaults: defaults) == "⌘⇧D")
	}

	@Test func theShortcutIsOffUntilTurnedOn() {
		let settings = CleanUpSettings(defaults: isolatedDefaults())
		#expect(!settings.isOnRequestEnabled)
		#expect(settings.shortcut == "⌥⇧Space")
	}
}
