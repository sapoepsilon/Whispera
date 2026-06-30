import Foundation
import Testing

@testable import Whispera

struct RecipeMatcherTests {

	private func recipe(_ name: String, trigger: String?) -> Recipe {
		Recipe(name: name, triggerPhrase: trigger, steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
	}

	private var recipes: [Recipe] {
		[
			recipe("Polish", trigger: nil),
			recipe("Make professional", trigger: "make professional"),
			recipe("Make professional report", trigger: "make professional report"),
			recipe("Summarize", trigger: "summarize"),
		]
	}

	@Test func matchesTriggerAndStripsRemainder() {
		let match = RecipeMatcher.match(text: "make professional hey send the file", recipes: recipes)
		#expect(match?.recipe.name == "Make professional")
		#expect(match?.remainder == "hey send the file")
	}

	@Test func longestTriggerWins() {
		let match = RecipeMatcher.match(text: "make professional report about sales", recipes: recipes)
		#expect(match?.recipe.name == "Make professional report")
		#expect(match?.remainder == "about sales")
	}

	@Test func caseInsensitive() {
		let match = RecipeMatcher.match(text: "MAKE Professional hello", recipes: recipes)
		#expect(match?.recipe.name == "Make professional")
	}

	@Test func whitespaceTolerant() {
		let match = RecipeMatcher.match(text: "  make    professional   hello ", recipes: recipes)
		#expect(match?.recipe.name == "Make professional")
		#expect(match?.remainder == "hello")
	}

	@Test func punctuationTolerant() {
		let match = RecipeMatcher.match(text: "Summarize, this whole thing", recipes: recipes)
		#expect(match?.recipe.name == "Summarize")
		#expect(match?.remainder == "this whole thing")
	}

	@Test func noMatchReturnsNil() {
		#expect(RecipeMatcher.match(text: "just some normal dictation", recipes: recipes) == nil)
	}

	@Test func triggerOnlyWithEmptyRemainder() {
		let match = RecipeMatcher.match(text: "summarize", recipes: recipes)
		#expect(match?.recipe.name == "Summarize")
		#expect(match?.remainder == "")
	}

	@Test func nilTriggerNeverMatches() {
		let onlyPolish = [recipe("Polish", trigger: nil)]
		#expect(RecipeMatcher.match(text: "anything at all", recipes: onlyPolish) == nil)
	}

	@Test func partialWordDoesNotMatch() {
		// "summarizes" should not trigger "summarize".
		#expect(RecipeMatcher.match(text: "summarizes the report", recipes: recipes) == nil)
	}
}

@MainActor
@Suite(.serialized)
struct DictationCoordinatorTests {

	private func storeWithRecipe() async -> (RecipeStore, URL) {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString).json")
		let store = RecipeStore(auth: AuthManager(), fileURL: url)
		await store.create(
			Recipe(
				name: "Make professional", triggerPhrase: "make professional",
				steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))]))
		return (store, url)
	}

	@Test func noMatchReturnsRawText() async {
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { _, _ in "SHOULD NOT RUN" }
		let result = await coordinator.process("just normal words")
		#expect(result == "just normal words")
	}

	@Test func matchRunsRecipeAndReturnsOutput() async {
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { recipe, input in
			#expect(recipe.name == "Make professional")
			#expect(input == "hey send the file")
			return "Could you please send the file?"
		}
		let result = await coordinator.process("make professional hey send the file")
		#expect(result == "Could you please send the file?")
	}

	@Test func emptyOutputReturnsNilAndSetsError() async {
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { _, _ in "   " }
		let result = await coordinator.process("make professional hi")
		#expect(result == nil)
		#expect(coordinator.lastError != nil)
	}

	@Test func executionErrorFallsBackToRawText() async {
		struct Boom: Error {}
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { _, _ in throw Boom() }
		let result = await coordinator.process("make professional hi there")
		#expect(result == "make professional hi there")
		#expect(coordinator.lastError != nil)
	}

	/// Drives the "Running <recipe>…" indicator: while a recipe executes,
	/// isRunning is true and runningRecipeName is set; both clear afterward.
	@Test func exposesRunningStateDuringExecution() async {
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }

		var resume: (() -> Void)?
		let coordinator = DictationCoordinator(store: store) { _, _ in
			await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
				resume = { cont.resume() }
			}
			return "done"
		}

		let task = Task { await coordinator.process("make professional hi") }
		while resume == nil { await Task.yield() }

		#expect(coordinator.isRunning)
		#expect(coordinator.runningRecipeName == "Make professional")

		resume?()
		let result = await task.value
		#expect(result == "done")
		#expect(!coordinator.isRunning)
		#expect(coordinator.runningRecipeName == nil)
	}

	@Test func emptyResultSetsOverlayError() async {
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { _, _ in "   " }
		_ = await coordinator.process("make professional hi")
		#expect(coordinator.overlayError != nil)
	}

	@Test func executionErrorSetsOverlayError() async {
		struct Boom: LocalizedError { var errorDescription: String? { "kaboom" } }
		let (store, url) = await storeWithRecipe()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store) { _, _ in throw Boom() }
		_ = await coordinator.process("make professional hi")
		#expect(coordinator.overlayError == "kaboom")
	}

	// MARK: - Default post-action command (WHI-49)

	/// Builds a store with a trigger command ("Make professional") plus a
	/// trigger-less default command ("Polish"), returning the default's id.
	private func storeWithTriggerAndDefault() async -> (RecipeStore, String, URL) {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(UUID().uuidString).json")
		let store = RecipeStore(auth: AuthManager(), fileURL: url)
		await store.create(
			Recipe(
				name: "Make professional", triggerPhrase: "make professional",
				steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))]))
		let def = Recipe(name: "Polish", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
		await store.create(def)
		return (store, def.id, url)
	}

	@Test func defaultCommandRunsWhenNoTriggerMatches() async {
		let (store, defId, url) = await storeWithTriggerAndDefault()
		defer { try? FileManager.default.removeItem(at: url) }
		var ranWith: (name: String, input: String)?
		let coordinator = DictationCoordinator(store: store, defaultCommandId: { defId }) { recipe, input in
			ranWith = (recipe.name, input)
			return "POLISHED"
		}
		let result = await coordinator.process("just some plain words")
		#expect(result == "POLISHED")
		#expect(ranWith?.name == "Polish")
		// The whole transcript is the input for the default command.
		#expect(ranWith?.input == "just some plain words")
	}

	@Test func triggerWinsOverDefault() async {
		let (store, defId, url) = await storeWithTriggerAndDefault()
		defer { try? FileManager.default.removeItem(at: url) }
		var ranWith: (name: String, input: String)?
		let coordinator = DictationCoordinator(store: store, defaultCommandId: { defId }) { recipe, input in
			ranWith = (recipe.name, input)
			return "OUT"
		}
		_ = await coordinator.process("make professional hello there")
		#expect(ranWith?.name == "Make professional")
		#expect(ranWith?.input == "hello there")
	}

	@Test func noDefaultAndNoTriggerPastesRaw() async {
		let (store, _, url) = await storeWithTriggerAndDefault()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store, defaultCommandId: { "" }) { _, _ in
			"SHOULD NOT RUN"
		}
		let result = await coordinator.process("plain words no trigger")
		#expect(result == "plain words no trigger")
	}

	@Test func staleDefaultIdFallsBackToRaw() async {
		let (store, _, url) = await storeWithTriggerAndDefault()
		defer { try? FileManager.default.removeItem(at: url) }
		let coordinator = DictationCoordinator(store: store, defaultCommandId: { "nonexistent-id" }) { _, _ in
			"SHOULD NOT RUN"
		}
		let result = await coordinator.process("plain words")
		#expect(result == "plain words")
	}
}
