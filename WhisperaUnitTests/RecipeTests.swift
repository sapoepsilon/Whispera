import Foundation
import Testing

@testable import Whispera

struct RecipeCodableTests {

	@Test func decodesBackendRecipeIgnoringExtraFields() throws {
		let json = #"""
			{
			  "id": "11111111-1111-1111-1111-111111111111",
			  "userId": "22222222-2222-2222-2222-222222222222",
			  "name": "Make professional",
			  "description": "Rewrites politely",
			  "triggerPhrase": "make professional",
			  "steps": [{"type":"llm","name":"rewrite","config":{"provider":"openai","model":"gpt-5.4-mini","prompt":"Rewrite {{input}}"}}],
			  "integrations": null,
			  "permissions": null,
			  "outputFormat": "text",
			  "isPublic": false,
			  "createdAt": "2026-01-01T00:00:00.000Z",
			  "updatedAt": "2026-01-01T00:00:00.000Z",
			  "deletedAt": null
			}
			"""#
		let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
		#expect(recipe.name == "Make professional")
		#expect(recipe.triggerPhrase == "make professional")
		#expect(recipe.steps.first?.config.model == "gpt-5.4-mini")
		#expect(recipe.steps.first?.config.prompt == "Rewrite {{input}}")
	}

	@Test func recipeInputOmitsNilFields() throws {
		let recipe = Recipe(
			name: "Summarize", triggerPhrase: nil,
			steps: [RecipeStep(config: LLMStepConfig(prompt: "Summarize {{input}}"))])
		let data = try JSONEncoder().encode(RecipeInput(from: recipe))
		let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

		#expect(object["name"] as? String == "Summarize")
		#expect(object["triggerPhrase"] == nil)
		#expect(object["description"] == nil)
		let steps = object["steps"] as! [[String: Any]]
		let config = steps[0]["config"] as! [String: Any]
		#expect(config["prompt"] as? String == "Summarize {{input}}")
		#expect(config["model"] == nil)
	}
}

@MainActor
@Suite(.serialized)
struct RecipeStoreLocalTests {

	private func tempStore() -> (RecipeStore, URL) {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("recipes-\(UUID().uuidString).json")
		// Signed-out AuthManager → store stays in local mode (no network).
		let store = RecipeStore(auth: AuthManager(), fileURL: url)
		return (store, url)
	}

	@Test func createPersistsLocallyAndReloads() async {
		let (store, url) = tempStore()
		defer { try? FileManager.default.removeItem(at: url) }

		await store.create(
			Recipe(
				name: "Test", triggerPhrase: "test",
				steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))]))
		#expect(store.recipes.count == 1)

		let reloaded = RecipeStore(auth: AuthManager(), fileURL: url)
		#expect(reloaded.recipes.count == 1)
		#expect(reloaded.recipes.first?.name == "Test")
	}

	@Test func deleteRemovesLocally() async {
		let (store, url) = tempStore()
		defer { try? FileManager.default.removeItem(at: url) }

		let recipe = Recipe(name: "X", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
		await store.create(recipe)
		await store.delete(recipe)
		#expect(store.recipes.isEmpty)
	}

	@Test func loadDefaultsPopulatesLocalStarterSet() async {
		let (store, url) = tempStore()
		defer { try? FileManager.default.removeItem(at: url) }

		await store.loadDefaults()
		#expect(!store.recipes.isEmpty)
		#expect(store.recipes.contains { $0.triggerPhrase == "make professional" })
	}
}
