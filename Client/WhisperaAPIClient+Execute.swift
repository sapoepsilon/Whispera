// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

struct RecipeExecutionResult: Decodable, Sendable {
	let status: String
	let output: String?
	let error: String?
}

private struct ExecuteBody: Encodable {
	let input: String
}

extension WhisperaAPIClient {
	/// Executes a recipe server-side. Pass `providerKey` for BYOK (sent as
	/// `X-Provider-Key`); omit for Subscription (platform keys via Bearer auth).
	func executeRecipe(id: String, input: String, providerKey: String? = nil) async throws
		-> RecipeExecutionResult
	{
		try await send(
			"/recipes/\(id)/execute", method: "POST", body: ExecuteBody(input: input),
			providerKey: providerKey)
	}
}
