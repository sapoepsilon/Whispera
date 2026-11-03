import Foundation
import WhisperaOpenAI

/// What a recipe step needs from whatever runs it.
///
/// Owned by this package rather than taken from the client package, so a host
/// can run recipes against something that is not an HTTP endpoint at all — an
/// on-device model, a stub in a test — without this package growing a second
/// code path for it.
public protocol RecipeStepExecuting: Sendable {
	func complete(
		system: String?,
		prompt: String,
		model: String?,
		temperature: Double?,
		maxTokens: Int?
	) async throws -> String
}

/// Anything that can turn a recipe and an input into text.
public protocol RecipeExecuting: Sendable {
	func run(recipe: Recipe, input: String) async throws -> String
}

public enum RecipePipelineError: LocalizedError, Equatable {
	case noSteps
	case emptyOutput(step: Int)

	public var errorDescription: String? {
		switch self {
		case .noSteps:
			return "This command has no steps to run."
		case .emptyOutput(let step):
			return "Step \(step + 1) returned nothing."
		}
	}
}

/// Runs a recipe's steps in order, feeding each step's output into the next.
public struct RecipePipeline: RecipeExecuting {
	private let executor: RecipeStepExecuting

	public init(executor: RecipeStepExecuting) {
		self.executor = executor
	}

	public func run(recipe: Recipe, input: String) async throws -> String {
		guard !recipe.steps.isEmpty else { throw RecipePipelineError.noSteps }

		var current = input
		var outputs: [String] = []
		for (index, step) in recipe.steps.enumerated() {
			let config = step.config
			let prompt = Self.interpolate(config.prompt, input: current, stepOutputs: outputs)
			let system = config.systemPrompt.map {
				Self.interpolate($0, input: current, stepOutputs: outputs)
			}
			current = try await executor.complete(
				system: system,
				prompt: prompt,
				model: config.model,
				temperature: config.temperature,
				maxTokens: config.maxTokens)
			guard !current.isEmpty else { throw RecipePipelineError.emptyOutput(step: index) }
			outputs.append(current)
		}
		return current
	}

	/// The template syntax, which is deliberately the smallest thing that works:
	/// the original input, and any earlier step's output by index.
	public static func interpolate(
		_ template: String, input: String, stepOutputs: [String]
	) -> String {
		var result = template.replacingOccurrences(of: "{{input}}", with: input)
		for (index, output) in stepOutputs.enumerated() {
			result = result.replacingOccurrences(of: "{{steps[\(index)].output}}", with: output)
		}
		return result
	}
}

/// Runs steps against an OpenAI-compatible server.
///
/// A step naming no model falls back to the host's configured default, which is
/// what lets one recipe run against a local 3B model on one machine and a hosted
/// one on another without editing the recipe.
public struct OpenAIStepExecutor: RecipeStepExecuting {
	private let client: OpenAICompatibleClient
	private let defaultModel: @Sendable () -> String

	public init(client: OpenAICompatibleClient, defaultModel: @escaping @Sendable () -> String) {
		self.client = client
		self.defaultModel = defaultModel
	}

	public init(client: OpenAICompatibleClient, defaultModel: String) {
		self.init(client: client, defaultModel: { defaultModel })
	}

	public func complete(
		system: String?,
		prompt: String,
		model: String?,
		temperature: Double?,
		maxTokens: Int?
	) async throws -> String {
		let resolved = (model?.isEmpty == false ? model : nil) ?? defaultModel()
		guard !resolved.isEmpty else { throw OpenAIError.noModel }
		return try await client.complete(
			system: system, prompt: prompt, model: resolved, temperature: temperature,
			maxTokens: maxTokens)
	}
}

extension RecipePipeline {
	/// The common wiring, spelled once.
	public static func openAI(
		client: OpenAICompatibleClient, defaultModel: @escaping @Sendable () -> String
	) -> RecipePipeline {
		RecipePipeline(executor: OpenAIStepExecutor(client: client, defaultModel: defaultModel))
	}
}
