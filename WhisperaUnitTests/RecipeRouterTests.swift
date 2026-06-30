import Foundation
import Testing

@testable import Whispera

@MainActor
@Suite(.serialized)
struct RecipeRouterTests {

	private func recipe(provider: String? = nil) -> Recipe {
		Recipe(
			name: "r",
			steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}", provider: provider))])
	}

	@Test func localModeReturnsLocalExecutor() throws {
		let router = RecipeRouter(auth: AuthManager(), modeProvider: { .local })
		#expect(try router.executor(for: recipe()) is LocalLLMExecutor)
	}

	@Test func subscriptionModeRequiresSignIn() {
		let router = RecipeRouter(auth: AuthManager(), modeProvider: { .subscription })
		#expect(throws: RecipeRouterError.self) { _ = try router.executor(for: recipe()) }
	}

	@Test func byokModeRequiresSignIn() {
		let router = RecipeRouter(auth: AuthManager(), modeProvider: { .byok })
		#expect(throws: RecipeRouterError.self) { _ = try router.executor(for: recipe()) }
	}

	@Test func providerSelectionFromStepConfig() {
		#expect(RecipeRouter.provider(for: recipe(provider: "claude")) == .anthropic)
		#expect(RecipeRouter.provider(for: recipe(provider: "anthropic")) == .anthropic)
		#expect(RecipeRouter.provider(for: recipe(provider: "openai")) == .openai)
		#expect(RecipeRouter.provider(for: recipe(provider: nil)) == .openai)
	}
}

struct BackendExecutorTests {

	private func api(mock: MockURLProtocol.Mock) -> (WhisperaAPIClient, AuthTokenStore) {
		let store = AuthTokenStore(service: "com.whispera.clerk.test.\(UUID().uuidString)")
		try? store.save("t")
		let api = WhisperaAPIClient(
			session: mock.session, tokenStore: store, serverURLProvider: { mock.baseURL })
		return (api, store)
	}

	private func recipe() -> Recipe {
		Recipe(id: "rid", name: "r", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
	}

	@Test func completedStatusReturnsOutput() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"status":"completed","output":"done","error":null}"#)
		let (client, store) = api(mock: mock)
		defer { try? store.delete() }
		let executor = BackendExecutor(providerKey: nil, api: client)
		#expect(try await executor.run(recipe: recipe(), input: "x") == "done")
	}

	@Test func failedStatusThrows() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"status":"failed","output":null,"error":"boom"}"#)
		let (client, store) = api(mock: mock)
		defer { try? store.delete() }
		let executor = BackendExecutor(providerKey: nil, api: client)
		await #expect(throws: RecipeRouterError.self) { _ = try await executor.run(recipe: recipe(), input: "x") }
	}
}
