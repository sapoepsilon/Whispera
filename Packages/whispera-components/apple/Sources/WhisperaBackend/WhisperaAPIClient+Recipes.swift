import Foundation
import WhisperaRecipes

private struct RecipeListResponse: Decodable {
	let data: [Recipe]
}

private struct SeedResponse: Decodable {
	let created: Int
}

private struct EmptyBody: Encodable {}

extension WhisperaAPIClient {
	public func listRecipes() async throws -> [Recipe] {
		let response: RecipeListResponse = try await get("/recipes?limit=100")
		return response.data
	}

	public func createRecipe(_ input: RecipeInput) async throws -> Recipe {
		try await send("/recipes", method: "POST", body: input)
	}

	public func updateRecipe(id: String, _ input: RecipeInput) async throws -> Recipe {
		try await send("/recipes/\(id)", method: "PUT", body: input)
	}

	public func deleteRecipe(id: String) async throws {
		try await sendNoContent("/recipes/\(id)", method: "DELETE", body: Optional<RecipeInput>.none)
	}

	/// Idempotent server-side seeding of the starter set.
	@discardableResult
	public func seedDefaultRecipes() async throws -> Int {
		let response: SeedResponse = try await send(
			"/recipes/seed-defaults", method: "POST", body: EmptyBody())
		return response.created
	}
}
