// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// A single recipe step. v1 only supports `llm` (text in → text out); the
/// config mirrors the backend `llm` handler. See WHI-30 / WHI-38.
struct RecipeStep: Codable, Equatable, Sendable {
	var type: String
	var name: String?
	var config: LLMStepConfig

	init(type: String = "llm", name: String? = nil, config: LLMStepConfig) {
		self.type = type
		self.name = name
		self.config = config
	}
}

struct LLMStepConfig: Codable, Equatable, Sendable {
	var prompt: String
	var systemPrompt: String?
	var provider: String?
	var model: String?
	var temperature: Double?
	var maxTokens: Int?

	init(
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

/// A recipe ("Command" in the UI). Maps to the backend `recipe` resource; local
/// recipes get a locally-generated `id`.
struct Recipe: Codable, Identifiable, Equatable, Sendable {
	let id: String
	var name: String
	var description: String?
	var triggerPhrase: String?
	var steps: [RecipeStep]
	var outputFormat: String

	init(
		id: String = UUID().uuidString,
		name: String,
		description: String? = nil,
		triggerPhrase: String? = nil,
		steps: [RecipeStep],
		outputFormat: String = "text"
	) {
		self.id = id
		self.name = name
		self.description = description
		self.triggerPhrase = triggerPhrase
		self.steps = steps
		self.outputFormat = outputFormat
	}

	/// Decodes leniently — the backend sends extra fields (userId, timestamps,
	/// isPublic, …) that the client doesn't need.
	enum CodingKeys: String, CodingKey {
		case id, name, description, triggerPhrase, steps, outputFormat
	}
}

/// Writable payload for create/update. Omits server-managed fields.
struct RecipeInput: Encodable, Sendable {
	var name: String
	var description: String?
	var triggerPhrase: String?
	var steps: [RecipeStep]
	var outputFormat: String

	init(from recipe: Recipe) {
		self.name = recipe.name
		self.description = recipe.description
		self.triggerPhrase = recipe.triggerPhrase
		self.steps = recipe.steps
		self.outputFormat = recipe.outputFormat
	}
}
