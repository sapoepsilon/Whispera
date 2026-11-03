import Foundation
import WhisperaRecipes

public struct RecipeExecutionResult: Decodable, Sendable, Equatable {
	public let status: String
	public let output: String?
	public let error: String?
}

private struct ExecuteBody: Encodable {
	let input: String
}

extension WhisperaAPIClient {
	/// Executes a recipe server-side. `providerKey` is sent as `X-Provider-Key`
	/// for a user's own key; omit it where the backend holds the credentials.
	public func executeRecipe(id: String, input: String, providerKey: String? = nil) async throws
		-> RecipeExecutionResult
	{
		try await send(
			"/recipes/\(id)/execute", method: "POST", body: ExecuteBody(input: input),
			providerKey: providerKey)
	}
}

public enum BackendExecutorError: LocalizedError, Equatable {
	case executionFailed(String)

	public var errorDescription: String? {
		switch self {
		case .executionFailed(let message): return message
		}
	}
}

/// Runs a recipe through the backend's execute endpoint instead of against a
/// model server directly.
///
/// Parked, and deliberately so: nothing constructs this while the client ships
/// without accounts. It conforms to the recipes package's own `RecipeExecuting`
/// so restoring the backend path is a matter of handing this to the pipeline's
/// caller, not of rewriting it.
public struct BackendExecutor: RecipeExecuting {
	public let providerKey: String?
	private let api: WhisperaAPIClient

	public init(api: WhisperaAPIClient, providerKey: String? = nil) {
		self.api = api
		self.providerKey = providerKey
	}

	public func run(recipe: Recipe, input: String) async throws -> String {
		let result = try await api.executeRecipe(
			id: recipe.id, input: input, providerKey: providerKey)
		guard result.status == "completed", let output = result.output, !output.isEmpty else {
			throw BackendExecutorError.executionFailed(result.error ?? "Recipe execution failed")
		}
		return output
	}
}
