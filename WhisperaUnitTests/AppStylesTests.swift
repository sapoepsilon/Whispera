// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaRecipes

@testable import Whispera

private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
	let suite = "AppStylesTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	defaults.removePersistentDomain(forName: suite)
	return defaults
}

private func tempFile(_ name: String) -> URL {
	FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
}

private func enabledSettings() -> WhisperaRecipes.AppStyleSettings {
	var settings = WhisperaRecipes.AppStyleSettings.defaults
	settings.enabled = true
	return settings
}

// MARK: - Resolver

struct AppCategoryResolverTests {
	private let defaults = WhisperaRecipes.AppStyleSettings.defaults

	@Test func exactHitsPerCategory() {
		#expect(AppCategoryResolver.category(for: "com.apple.MobileSMS", settings: defaults) == .personal)
		#expect(AppCategoryResolver.category(for: "com.tinyspeck.slackmacgap", settings: defaults) == .work)
		#expect(AppCategoryResolver.category(for: "com.apple.mail", settings: defaults) == .email)
		#expect(AppCategoryResolver.category(for: "com.microsoft.VSCode", settings: defaults) == .code)
		#expect(AppCategoryResolver.category(for: "com.apple.Notes", settings: defaults) == .other)
		#expect(AppCategoryResolver.category(for: "com.tinyspeck.chatlyio", settings: defaults) == .work)
		#expect(AppCategoryResolver.category(for: "com.apple.mobilemail", settings: defaults) == .email)
	}

	@Test func matchingIgnoresCase() {
		#expect(AppCategoryResolver.category(for: "COM.APPLE.MAIL", settings: defaults) == .email)
		#expect(AppCategoryResolver.category(for: "com.apple.mobilesms", settings: defaults) == .personal)
	}

	@Test func prefixesMatchAfterExactMisses() {
		#expect(AppCategoryResolver.category(for: "com.jetbrains.goland", settings: defaults) == .code)
		#expect(AppCategoryResolver.category(for: "com.google.android.studio-EAP", settings: defaults) == .code)
	}

	@Test func overrideBeatsBuiltInAndCanDemoteToOther() {
		var settings = defaults
		settings.setOverride("com.apple.Notes", to: .work)
		settings.setOverride("com.tinyspeck.slackmacgap", to: .other)
		#expect(AppCategoryResolver.category(for: "com.apple.notes", settings: settings) == .work)
		#expect(AppCategoryResolver.category(for: "com.tinyspeck.slackmacgap", settings: settings) == .other)
	}

	@Test func missingOrOwnIdsAreOther() {
		#expect(AppCategoryResolver.category(for: nil, settings: defaults) == .other)
		#expect(AppCategoryResolver.category(for: "", settings: defaults) == .other)
		#expect(AppCategoryResolver.category(for: "  ", settings: defaults) == .other)
		#expect(AppCategoryResolver.category(for: "com.macwhisper.app", settings: defaults) == .other)
	}

	@MainActor
	@Test func whisperaItselfIsCapturedAsUnknown() {
		let context = FrontmostAppContext.capture(frontmost: .current, ownBundleID: Bundle.main.bundleIdentifier)
		#expect(context.bundleID == nil)
		#expect(context.platform == .mac)
	}

	@Test func catalogIdsAreUniqueAndInOneCategory() {
		let ids = AppCategoryCatalog.entries.map(\.bundleID)
		#expect(Set(ids).count == ids.count)
		let lowered = ids.map { $0.lowercased() }
		#expect(Set(lowered).count == lowered.count)
		var seen: [String: AppCategory] = [:]
		for entry in AppCategoryCatalog.entries {
			let key = entry.bundleID.lowercased()
			if let previous = seen[key] { #expect(previous == entry.category, "\(key) in two categories") }
			seen[key] = entry.category
		}
		#expect(AppCategoryCatalog.exact.count == lowered.count)
	}
}

// MARK: - Styles and settings

struct DictationStyleTests {
	@Test func allowedMatrix() {
		#expect(DictationStyle.allowed(in: .personal) == [.formal, .casual, .veryCasual])
		#expect(DictationStyle.allowed(in: .work) == [.formal, .casual, .excited])
		#expect(DictationStyle.allowed(in: .email) == [.formal, .casual, .excited])
		#expect(DictationStyle.allowed(in: .other) == [.formal, .casual, .excited])
		#expect(DictationStyle.allowed(in: .code) == [.verbatim, .casual])
	}

	@Test func defaultsMatchTheSpec() {
		let settings = WhisperaRecipes.AppStyleSettings.defaults
		#expect(settings.enabled == false)
		#expect(settings.style(for: .personal) == .casual)
		#expect(settings.style(for: .work) == .casual)
		#expect(settings.style(for: .email) == .formal)
		#expect(settings.style(for: .code) == .verbatim)
		#expect(settings.style(for: .other) == .formal)
	}

	@Test func aStoredStyleTheCategoryDoesNotAllowFallsBack() throws {
		let json: String = #"{"enabled":true,"styles":{"work":"veryCasual","code":"formal","personal":"bogus","newcat":"casual"},"overrides":{"COM.Example.App":"email","x.y":"nope"},"version":1}"#
		let settings = try JSONDecoder().decode(WhisperaRecipes.AppStyleSettings.self, from: Data(json.utf8))
		#expect(settings.style(for: .work) == .formal)
		#expect(settings.style(for: .code) == .verbatim)
		#expect(settings.style(for: .personal) == .formal)
		#expect(settings.style(for: .email) == .formal)
		#expect(settings.overrides == ["com.example.app": .email])
	}
}

struct AppStyleSettingsStoreTests {
	@Test func roundTrip() throws {
		let url = tempFile("app-styles")
		defer { try? FileManager.default.removeItem(at: url) }
		let store = AppStyleSettingsStore(fileURL: url)
		var settings = enabledSettings()
		settings.styles[.personal] = .veryCasual
		settings.setOverride("com.apple.Notes", to: .work)
		try store.save(settings)
		#expect(store.load() == settings)
	}

	@Test func missingFileGivesDefaults() {
		#expect(AppStyleSettingsStore(fileURL: tempFile("missing")).load() == .defaults)
	}

	@Test func corruptFileGivesDefaultsAndIsLeftAlone() throws {
		let url = tempFile("corrupt")
		defer { try? FileManager.default.removeItem(at: url) }
		let garbage = Data("{not json".utf8)
		try garbage.write(to: url)
		#expect(AppStyleSettingsStore(fileURL: url).load() == .defaults)
		#expect(try Data(contentsOf: url) == garbage)
	}

	@Test func olderVersionsAreBroughtUpToDate() throws {
		let url = tempFile("v0")
		defer { try? FileManager.default.removeItem(at: url) }
		try Data(#"{"enabled":true,"version":0}"#.utf8).write(to: url)
		let loaded = AppStyleSettingsStore(fileURL: url).load()
		#expect(loaded.version == WhisperaRecipes.AppStyleSettings.currentVersion)
		#expect(loaded.enabled)
	}
}

// MARK: - Fragments

struct StyleFragmentTests {
	@Test func verbatimAddsNothing() {
		#expect(StyleFragment.text(.verbatim, category: .code) == nil)
	}

	@Test func addOnsOnlyForTheirCategories() throws {
		let email = try #require(StyleFragment.text(.formal, category: .email))
		#expect(email.contains(StyleFragment.emailAddOn))
		#expect(email.contains("an email"))
		let code = try #require(StyleFragment.text(.casual, category: .code))
		#expect(code.contains(StyleFragment.codeAddOn))
		let work = try #require(StyleFragment.text(.casual, category: .work))
		#expect(!work.contains(StyleFragment.emailAddOn))
		#expect(!work.contains(StyleFragment.codeAddOn))
		#expect(work.contains("a work chat message"))
	}

	@Test func appendedAfterAnExistingSystemPrompt() throws {
		let recipe = Recipe(
			id: "custom", name: "Custom",
			steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}", systemPrompt: "Be terse."))],
			applyAppStyle: true)
		let context = DictationAppContext(bundleID: "com.apple.mail", platform: .mac)
		let styled = try #require(AppStyleComposer.apply(to: recipe, settings: enabledSettings(), context: context))
		let system = try #require(styled.recipe.steps[0].config.systemPrompt)
		#expect(system.hasPrefix("Be terse.\n\n"))
		#expect(system.contains(StyleFragment.emailAddOn))
		#expect(styled.recipe.steps[0].config.prompt == "{{input}}")
	}

	@Test func onlyTheLastStepIsStyled() throws {
		let recipe = Recipe(
			id: AppStyleComposer.cleanUpRecipeID, name: "Clean up",
			steps: [
				RecipeStep(config: LLMStepConfig(prompt: "one {{input}}")),
				RecipeStep(config: LLMStepConfig(prompt: "two {{steps[0].output}}")),
			])
		let styled = try #require(AppStyleComposer.apply(to: recipe, settings: enabledSettings(), context: nil))
		#expect(styled.recipe.steps[0].config.systemPrompt == nil)
		#expect(styled.recipe.steps[1].config.systemPrompt?.contains("general writing") == true)
	}

	@Test func theBuiltInIdMatchesTheApp() {
		#expect(AppStyleComposer.cleanUpRecipeID == CleanUpRecipe.id)
	}
}

// MARK: - Coordinator

private final class RunCapture: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: [Recipe] = []
	var recipes: [Recipe] { lock.withLock { stored } }
	func append(_ recipe: Recipe) { lock.withLock { stored.append(recipe) } }
}

@MainActor
private func makeStore(_ recipes: [Recipe]) async -> Whispera.RecipeStore {
	let store = Whispera.RecipeStore(fileURL: tempFile("recipes"))
	for recipe in recipes { await store.create(recipe) }
	return store
}

@MainActor
private func coordinator(
	store: Whispera.RecipeStore, settings: WhisperaRecipes.AppStyleSettings, capture: RunCapture,
	recipesOn: Bool = false, defaultId: String = ""
) -> DictationCoordinator {
	DictationCoordinator(
		store: store, health: RecipeRunHealth(defaults: isolatedDefaults()), isEnabled: { recipesOn },
		defaultCommandId: { defaultId }, styleSettings: { settings }
	) { recipe, input in
		capture.append(recipe)
		return "done: \(input)"
	}
}

@MainActor
@Suite(.serialized)
struct DictationCoordinatorStyleTests {
	private let messages = DictationAppContext(bundleID: "com.apple.MobileSMS", appName: "Messages", platform: .mac)

	@Test func stylesOffLeavesTheRecipeUnchanged() async {
		let capture = RunCapture()
		let cleanUp = CleanUpRecipe.make()
		let coordinator = coordinator(store: await makeStore([cleanUp]), settings: .defaults, capture: capture)
		let result = await coordinator.processDictation("hi there", cleanUp: true, context: messages)
		#expect(capture.recipes == [cleanUp])
		#expect(result?.history?.style == nil)
		#expect(result?.history?.appBundleID == "com.apple.MobileSMS")
	}

	@Test func cleanUpInMessagesGetsTheCasualFragment() async throws {
		let capture = RunCapture()
		let coordinator = coordinator(
			store: await makeStore([CleanUpRecipe.make()]), settings: enabledSettings(), capture: capture)
		let result = await coordinator.processDictation("hi there", cleanUp: true, context: messages)
		let system = try #require(capture.recipes.first?.steps.last?.config.systemPrompt)
		#expect(system == StyleFragment.text(.casual, category: .personal))
		#expect(capture.recipes.first?.steps.first?.config.prompt == CleanUpRecipe.defaultPrompt)
		#expect(result?.history?.style?.category == .personal)
		#expect(result?.history?.style?.style == .casual)
	}

	@Test func aCustomRecipeOnlyWhenItOptsIn() async throws {
		let plain = Recipe(id: "plain", name: "Plain", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
		let opted = Recipe(id: "opted", name: "Opted", steps: plain.steps, applyAppStyle: true)
		let capture = RunCapture()
		let store = await makeStore([plain, opted])
		let first = coordinator(
			store: store, settings: enabledSettings(), capture: capture, recipesOn: true, defaultId: "plain")
		_ = await first.processDictation("hello", cleanUp: false, context: messages)
		#expect(capture.recipes.last == plain)
		let second = coordinator(
			store: store, settings: enabledSettings(), capture: capture, recipesOn: true, defaultId: "opted")
		_ = await second.processDictation("hello", cleanUp: false, context: messages)
		#expect(capture.recipes.last?.steps[0].config.systemPrompt == StyleFragment.text(.casual, category: .personal))
	}

	@Test func noContextFormatsAsOther() async throws {
		let capture = RunCapture()
		let coordinator = coordinator(
			store: await makeStore([CleanUpRecipe.make()]), settings: enabledSettings(), capture: capture)
		let result = await coordinator.processDictation("hello", cleanUp: true)
		#expect(capture.recipes.first?.steps[0].config.systemPrompt == StyleFragment.text(.formal, category: .other))
		#expect(result?.history?.style?.category == .other)
	}

	@Test func historyCleanUpReusesTheStoredContext() async throws {
		let capture = RunCapture()
		let coordinator = coordinator(
			store: await makeStore([CleanUpRecipe.make()]), settings: enabledSettings(), capture: capture)
		let mail = DictationAppContext(bundleID: "com.apple.mail", appName: "Mail", platform: .mac)
		let record = await coordinator.cleanUpForHistory("hello", context: mail)
		#expect(capture.recipes.first?.steps[0].config.systemPrompt == StyleFragment.text(.formal, category: .email))
		#expect(record.style?.category == .email)
		#expect(record.appBundleID == "com.apple.mail")
	}

	@Test func codeIsVerbatimByDefault() async {
		let capture = RunCapture()
		let cleanUp = CleanUpRecipe.make()
		let coordinator = coordinator(store: await makeStore([cleanUp]), settings: enabledSettings(), capture: capture)
		let xcode = DictationAppContext(bundleID: "com.apple.dt.Xcode", platform: .mac)
		let result = await coordinator.processDictation("hello", cleanUp: true, context: xcode)
		#expect(capture.recipes == [cleanUp])
		#expect(result?.history?.style?.style == .verbatim)
	}

	@Test func historyEntryRemembersTheApp() {
		let entry = TranscriptionHistoryEntry(
			createdAt: Date(), text: "x", audioFileName: nil, durationSeconds: 0, modelName: nil, language: nil,
			source: .dictation)
		let style = AppStyleApplication(category: .personal, style: .casual, fragmentAdded: true)
		entry.apply(
			transcript: "x",
			postProcessing: HistoryPostProcessing(
				processedText: "X", promptName: "Clean up", promptTemplate: "", appBundleID: "com.apple.MobileSMS",
				appName: "Messages", style: style))
		#expect(entry.appContext?.bundleID == "com.apple.MobileSMS")
		#expect(entry.styleSummary?.contains("Messages") == true)
		#expect(entry.appStyle == "casual")
	}
}

// MARK: - Recipe coding

struct RecipeCodingTests {
	@Test func oldRecipesWithoutTheFlagDecode() throws {
		let stored: String = #"[{"id":"a","name":"A","steps":[{"type":"llm","config":{"prompt":"{{input}}"}}],"outputFormat":"text"}]"#
		let recipes: [WhisperaRecipes.Recipe] = try JSONDecoder().decode(
			[WhisperaRecipes.Recipe].self, from: Data(stored.utf8))
		#expect(recipes.first?.applyAppStyle == false)
	}

	@Test func roundTripKeepsTheFlag() throws {
		let recipe = Recipe(
			id: "b", name: "B", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))], applyAppStyle: true)
		let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
		#expect(decoded == recipe)
		#expect(decoded.applyAppStyle)
		let inputData = try JSONEncoder().encode(WhisperaRecipes.RecipeInput(from: recipe))
		let input = try JSONSerialization.jsonObject(with: inputData) as? [String: Any]
		#expect(input?["applyAppStyle"] as? Bool == true)
	}
}
