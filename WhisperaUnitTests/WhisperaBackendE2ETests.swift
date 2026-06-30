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
}
