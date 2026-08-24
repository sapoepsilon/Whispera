// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaBackend
import WhisperaDictation
import WhisperaRecipes

@testable import Whispera

/// What is left of the router once `LLMMode` is gone: reading the configured
/// LLM server and pointing the package pipeline at it. The two-arm
/// `executor(for:)` switch that both arms of returned the same executor is the
/// thing this ticket deleted. See WHI-91.
@MainActor
struct RecipeRouterTests {
	private func entry(url: String, model: String = "m") -> ServerEntry {
		ServerEntry(capability: .llm, urlString: url, model: model)
	}

	@Test func aConfiguredServerYieldsAnExecutor() throws {
		let router = RecipeRouter(entryProvider: { entry(url: "http://localhost:11434/v1") })
		#expect(throws: Never.self) { _ = try router.executor() }
	}

	/// The only failure the router itself can produce now. Everything else — a
	/// missing model, an unreachable host, an HTTP error — belongs to the
	/// package client and is reported by it.
	@Test func noServerConfiguredIsTheOnlyRouterFailure() {
		let router = RecipeRouter(entryProvider: { entry(url: "") })
		#expect(throws: RecipeRouterError.noServerConfigured) { _ = try router.executor() }
	}

	/// A bare host is not a server yet, and the router treats it the same as an
	/// empty field rather than building a client around an unusable URL.
	@Test func aHalfTypedAddressIsNotAServer() {
		let router = RecipeRouter(entryProvider: { entry(url: "http://") })
		#expect(throws: RecipeRouterError.noServerConfigured) { _ = try router.executor() }
	}

	/// The point of the collapse: an arbitrary cloud base URL is reachable
	/// without a provider enum, a mode switch, or a code change.
	@Test func anArbitraryCloudBaseURLIsJustAServer() throws {
		for url in [
			"https://api.groq.com/openai/v1",
			"https://openrouter.ai/api/v1",
			"https://api.anthropic.com/v1",
			"http://192.168.50.140:8000/v1",
		] {
			let router = RecipeRouter(entryProvider: { entry(url: url) })
			#expect(throws: Never.self) { _ = try router.executor() }
		}
	}
}

/// The backend execute path, now `WhisperaBackend.BackendExecutor`. Parked in
/// the app — nothing constructs it while there is no account — but still the
/// contract the client and the backend agreed on.
struct BackendExecutorTests {
	private func api(mock: MockURLProtocol.Mock) -> WhisperaAPIClient {
		WhisperaAPIClient(
			baseURL: mock.baseURL, credentials: StaticCredential(.bearer("t")), session: mock.session)
	}

	private func recipe() -> Recipe {
		Recipe(id: "rid", name: "r", steps: [RecipeStep(config: LLMStepConfig(prompt: "{{input}}"))])
	}

	@Test func completedStatusReturnsOutput() async throws {
		let mock = MockURLProtocol.make(
			status: 200, json: #"{"status":"completed","output":"done","error":null}"#)
		let executor = BackendExecutor(api: api(mock: mock))
		#expect(try await executor.run(recipe: recipe(), input: "x") == "done")
	}

	@Test func failedStatusThrows() async throws {
		let mock = MockURLProtocol.make(
			status: 200, json: #"{"status":"failed","output":null,"error":"boom"}"#)
		let executor = BackendExecutor(api: api(mock: mock))
		await #expect(throws: BackendExecutorError.self) {
			_ = try await executor.run(recipe: recipe(), input: "x")
		}
	}
}
