import Foundation
import Testing

@testable import Whispera

/// Live integration tests against a locally-running whispera-backend.
///
/// Opt-in: only runs when `WHISPERA_E2E=1` so normal/CI runs stay offline.
/// Start the backend first (NODE_ENV=test, port 3000) — see the project memory
/// `whispera-client-e2e-env`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WHISPERA_E2E"] == "1"))
struct WhisperaBackendE2ETests {

	private let baseURL = URL(string: "http://localhost:3000")!
	private let devToken = "whisperae2e"

	private func client(_ store: AuthTokenStore) -> WhisperaAPIClient {
		WhisperaAPIClient(tokenStore: store, serverURLProvider: { self.baseURL })
	}

	@Test func authMeReturnsClerkIdForDevToken() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)

		let user = try await client(store).getMe()
		#expect(user.clerkId == devToken)
	}

	@Test func recipeCrudRoundTripsAgainstBackend() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)
		let api = client(store)

		let unique = "E2E \(UUID().uuidString.prefix(8))"
		let created = try await api.createRecipe(
			RecipeInput(
				from: Recipe(
					name: unique, triggerPhrase: "e2e trigger",
					steps: [
						RecipeStep(config: LLMStepConfig(prompt: "echo {{input}}", model: "gpt-5.4-mini"))
					])))
		#expect(created.name == unique)

		let listed = try await api.listRecipes()
		#expect(listed.contains { $0.id == created.id })

		try await api.deleteRecipe(id: created.id)
		let afterDelete = try await api.listRecipes()
		#expect(!afterDelete.contains { $0.id == created.id })
	}

	/// Local executor runs against any OpenAI-compatible server. Points at
	/// VibeProxy (:8317) since no local model is pulled here.
	@Test func localExecutorRunsRecipeAgainstOpenAICompatibleServer() async throws {
		let executor = LocalLLMExecutor(
			serverURLProvider: { URL(string: "http://localhost:8317/v1") },
			defaultModelProvider: { "gpt-5.4-mini" })
		let recipe = Recipe(
			name: "echo",
			steps: [
				RecipeStep(
					config: LLMStepConfig(
						prompt: "Reply with exactly this word and nothing else: WHISPERA. Input: {{input}}")
				)
			])
		let output = try await executor.run(recipe: recipe, input: "ignored")
		#expect(output.uppercased().contains("WHISPERA"))
	}

	/// Subscription mode: create a recipe, execute it server-side via the backend
	/// (LLM through VibeProxy), assert the polished output, then clean up.
	@Test func subscriptionExecuteRoundTripsAgainstBackend() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)
		let api = client(store)

		let created = try await api.createRecipe(
			RecipeInput(
				from: Recipe(
					name: "E2E professional \(UUID().uuidString.prefix(6))",
					steps: [
						RecipeStep(
							config: LLMStepConfig(
								prompt: "Rewrite politely, output only the message: {{input}}",
								model: "gpt-5.4-mini"))
					])))
		defer { Task { try? await api.deleteRecipe(id: created.id) } }

		let executor = BackendExecutor(providerKey: nil, api: api)
		let output = try await executor.run(
			recipe: created, input: "hey send me the file by tomorrow")
		#expect(!output.isEmpty)
	}

	/// Full dictation flow: spoken text → trigger match → strip trigger →
	/// execute the matched recipe via backend → polished output. WHI-41 acceptance.
	@Test func dictationTriggerToExecuteFlowAgainstBackend() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)
		let api = client(store)

		let created = try await api.createRecipe(
			RecipeInput(
				from: Recipe(
					name: "Make professional \(UUID().uuidString.prefix(6))",
					triggerPhrase: "make professional",
					steps: [
						RecipeStep(
							config: LLMStepConfig(
								prompt:
									"Rewrite politely and professionally. Output only the message: {{input}}",
								model: "gpt-5.4-mini"))
					])))
		defer { Task { try? await api.deleteRecipe(id: created.id) } }

		let spoken = "make professional hey can you send me the file by tomorrow"
		let match = RecipeMatcher.match(text: spoken, recipes: [created])
		#expect(match?.recipe.id == created.id)
		#expect(match?.remainder == "hey can you send me the file by tomorrow")

		let output = try await BackendExecutor(providerKey: nil, api: api).run(
			recipe: created, input: match!.remainder)
		#expect(!output.isEmpty)
		// The polished output should not be the raw spoken phrase verbatim.
		#expect(output.lowercased() != spoken.lowercased())
	}

	/// WHI-49: a trigger-less default command post-processes plain dictation
	/// (no trigger phrase) end-to-end through the backend.
	@MainActor
	@Test func defaultCommandRunsOnPlainDictationViaBackend() async throws {
		let store = AuthTokenStore(service: "com.whispera.clerk.e2e.\(UUID().uuidString)")
		defer { try? store.delete() }
		try store.save(devToken)
		let api = client(store)

		let created = try await api.createRecipe(
			RecipeInput(
				from: Recipe(
					name: "Polish default \(UUID().uuidString.prefix(6))",
					steps: [
						RecipeStep(
							config: LLMStepConfig(
								prompt:
									"Clean up grammar and filler, output only the cleaned text: {{input}}",
								model: "gpt-5.4-mini"))
					])))
		defer { Task { try? await api.deleteRecipe(id: created.id) } }

		let recipeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"e2e-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: recipeURL) }
		let recipeStore = RecipeStore(auth: AuthManager(), fileURL: recipeURL)
		await recipeStore.create(created)

		let coordinator = DictationCoordinator(store: recipeStore, defaultCommandId: { created.id }) {
			recipe, input in
			try await BackendExecutor(providerKey: nil, api: api).run(recipe: recipe, input: input)
		}

		let result = await coordinator.process("um so like i wanted to say hi there")
		#expect(result != nil)
		#expect(!(result ?? "").isEmpty)
	}
}
