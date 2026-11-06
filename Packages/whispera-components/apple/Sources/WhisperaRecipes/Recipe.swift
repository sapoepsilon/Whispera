import Foundation

/// A single recipe step. Only `llm` (text in → text out) exists today; the
/// config mirrors the shape a server-side `llm` handler takes, so a recipe
/// written for one runs on the other unchanged.
public struct RecipeStep: Codable, Equatable, Sendable {
	public var type: String
	public var name: String?
	public var config: LLMStepConfig

	public init(type: String = "llm", name: String? = nil, config: LLMStepConfig) {
		self.type = type
		self.name = name
		self.config = config
	}
}

public struct LLMStepConfig: Codable, Equatable, Sendable {
	public var prompt: String
	public var systemPrompt: String?
	/// A hint, not a switch. Which server a step runs against is the host's
	/// choice; this only records what the recipe's author had in mind.
	public var provider: String?
	public var model: String?
	public var temperature: Double?
	public var maxTokens: Int?

	public init(
		prompt: String,
		systemPrompt: String? = nil,
		provider: String? = nil,
		model: String? = nil,
		temperature: Double? = nil,
		maxTokens: Int? = nil
	) {
		self.prompt = prompt
		self.systemPrompt = systemPrompt
		self.provider = provider
		self.model = model
		self.temperature = temperature
		self.maxTokens = maxTokens
	}
}

/// A recipe — a "Command" in the UI.
public struct Recipe: Codable, Identifiable, Equatable, Sendable {
	public let id: String
	public var name: String
	public var description: String?
	public var triggerPhrase: String?
	public var steps: [RecipeStep]
	public var outputFormat: String
	/// Opts a custom recipe into per-app styles. The built-in Clean up always qualifies.
	public var applyAppStyle: Bool

	public init(
		id: String = UUID().uuidString,
		name: String,
		description: String? = nil,
		triggerPhrase: String? = nil,
		steps: [RecipeStep],
		outputFormat: String = "text",
		applyAppStyle: Bool = false
	) {
		self.id = id
		self.name = name
		self.description = description
		self.triggerPhrase = triggerPhrase
		self.steps = steps
		self.outputFormat = outputFormat
		self.applyAppStyle = applyAppStyle
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		description = try container.decodeIfPresent(String.self, forKey: .description)
		triggerPhrase = try container.decodeIfPresent(String.self, forKey: .triggerPhrase)
		steps = try container.decode([RecipeStep].self, forKey: .steps)
		outputFormat = try container.decodeIfPresent(String.self, forKey: .outputFormat) ?? "text"
		applyAppStyle = try container.decodeIfPresent(Bool.self, forKey: .applyAppStyle) ?? false
	}

	/// Decodes leniently: a recipe that came from a server carries extra fields
	/// (userId, timestamps, isPublic, …) this package has no use for and refuses
	/// to learn about. Listing the keys is how the tolerance is expressed without
	/// importing a single backend type to get it.
	public enum CodingKeys: String, CodingKey {
		case id, name, description, triggerPhrase, steps, outputFormat, applyAppStyle
	}
}

/// The writable half, for a host that syncs recipes somewhere. Omits every
/// field whoever stores them is expected to manage.
public struct RecipeInput: Encodable, Sendable, Equatable {
	public var name: String
	public var description: String?
	public var triggerPhrase: String?
	public var steps: [RecipeStep]
	public var outputFormat: String
	public var applyAppStyle: Bool

	public init(from recipe: Recipe) {
		self.name = recipe.name
		self.description = recipe.description
		self.triggerPhrase = recipe.triggerPhrase
		self.steps = recipe.steps
		self.outputFormat = recipe.outputFormat
		self.applyAppStyle = recipe.applyAppStyle
	}
}

extension Recipe {
	/// The bundled starter set.
	public static var localDefaults: [Recipe] {
		[
			Recipe(
				name: "Make professional", triggerPhrase: "make professional",
				steps: [
					llmStep(
						"Rewrite this in a polite, professional tone. Output only the rewritten message, no preamble.\n\n{{input}}"
					)
				]),
			Recipe(
				name: "Fix grammar", triggerPhrase: "fix grammar",
				steps: [
					llmStep(
						"Fix any grammar and punctuation issues in this text. Preserve meaning and tone. Output only the corrected text.\n\n{{input}}"
					)
				]),
			Recipe(
				name: "Summarize", triggerPhrase: "summarize",
				steps: [llmStep("Summarize this in one sentence. Output only the summary.\n\n{{input}}")]),
			Recipe(
				name: "Bullet points", triggerPhrase: "bullet points",
				steps: [
					llmStep(
						"Convert this text into a clean list of bullet points (one per line, each starting with \"- \"). Output only the bullets.\n\n{{input}}"
					)
				]),
		]
	}

	private static func llmStep(_ prompt: String) -> RecipeStep {
		RecipeStep(name: "llm", config: LLMStepConfig(prompt: prompt))
	}
}
