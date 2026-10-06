// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

private struct RecipeListResponse: Decodable {
	let data: [Recipe]
}

private struct SeedResponse: Decodable {
	let created: Int
}

extension WhisperaAPIClient {
	func listRecipes() async throws -> [Recipe] {
		let response: RecipeListResponse = try await get("/recipes?limit=100")
		return response.data
	}

	func createRecipe(_ input: RecipeInput) async throws -> Recipe {
		try await send("/recipes", method: "POST", body: input)
	}

	func updateRecipe(id: String, _ input: RecipeInput) async throws -> Recipe {
		try await send("/recipes/\(id)", method: "PUT", body: input)
	}

	func deleteRecipe(id: String) async throws {
		try await sendNoContent("/recipes/\(id)", method: "DELETE", body: Optional<RecipeInput>.none)
	}

	/// Idempotent server-side seeding of the default starter recipes. WHI-46.
	@discardableResult
	func seedDefaultRecipes() async throws -> Int {
		let response: SeedResponse = try await send(
			"/recipes/seed-defaults", method: "POST", body: EmptyBody())
		return response.created
	}
}

private struct EmptyBody: Encodable {}
