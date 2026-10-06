// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

extension WhisperaSettings {
	private static let localURLKey = "whisperaLocalServerURL"
	private static let localModelKey = "whisperaLocalModel"

	/// Default points at a local OpenAI-compatible server (ollama). Works with
	/// any OpenAI-compatible runtime — llama-server, vLLM, LM Studio.
	static let defaultLocalServerURL = "http://localhost:11434/v1"

	static var localServerURLString: String {
		get { UserDefaults.standard.string(forKey: localURLKey) ?? defaultLocalServerURL }
		set { UserDefaults.standard.set(newValue, forKey: localURLKey) }
	}

	static var localServerURL: URL? {
		URL(string: localServerURLString.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	static var localModel: String {
		get { UserDefaults.standard.string(forKey: localModelKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: localModelKey) }
	}
}

enum LocalLLMError: LocalizedError {
	case unavailable
	case noModel
	case http(status: Int, body: String)
	case empty

	var errorDescription: String? {
		switch self {
		case .unavailable:
			return "Local mode unavailable — start a local model server or switch to BYOK."
		case .noModel:
			return "No local model set. Choose a model in Settings or set one on the recipe."
		case .http(let status, let body):
			return "Local model error (HTTP \(status))\(body.isEmpty ? "" : ": \(body)")"
		case .empty:
			return "Local model returned an empty response."
		}
	}
}

/// Runs a recipe's `llm` steps against any OpenAI-compatible chat endpoint —
/// the user's local server by default, or a hosted provider when an API key is
/// supplied (the BYOK path).
///
/// ponytail: this is the "local" path until on-device Apple Foundation Models
/// (`SystemLanguageModel` / `LanguageModelSession`) is wired in — deferred for
/// now (no model footprint on this machine). Any OpenAI-compatible local
/// runtime (ollama / llama-server / vLLM / LM Studio) works today. WHI-38.
struct LocalLLMExecutor {
	private let session: URLSession
	private let serverURLProvider: @Sendable () -> URL?
	private let defaultModelProvider: @Sendable () -> String
	private let apiKeyProvider: @Sendable () -> String?

	init(
		session: URLSession = .shared,
		serverURLProvider: @escaping @Sendable () -> URL? = { WhisperaSettings.localServerURL },
		defaultModelProvider: @escaping @Sendable () -> String = { WhisperaSettings.localModel },
		// Local servers and the proxies in front of them often want a bearer token;
		// empty/absent means no Authorization header, exactly as before.
		apiKeyProvider: @escaping @Sendable () -> String? = {
			(try? ByokKeyStore.shared.loadLocalServerKey()) ?? nil
		}
	) {
		self.session = session
		self.serverURLProvider = serverURLProvider
		self.defaultModelProvider = defaultModelProvider
		self.apiKeyProvider = apiKeyProvider
	}

	/// Runs each step in order, feeding each step's output into the next.
	func run(recipe: Recipe, input: String) async throws -> String {
		var current = input
		var outputs: [String] = []
		for step in recipe.steps {
			let config = step.config
			let prompt = Self.interpolate(config.prompt, input: current, stepOutputs: outputs)
			let system = config.systemPrompt.map { Self.interpolate($0, input: current, stepOutputs: outputs) }
			current = try await chat(
				system: system, prompt: prompt, model: config.model, maxTokens: config.maxTokens)
			outputs.append(current)
		}
		return current
	}

	func chat(system: String?, prompt: String, model: String?, maxTokens: Int?) async throws -> String {
		guard let base = serverURLProvider() else { throw LocalLLMError.unavailable }
		let resolvedModel = (model?.isEmpty == false ? model : nil) ?? nonEmpty(defaultModelProvider())
		guard let resolvedModel else { throw LocalLLMError.noModel }

		var messages: [[String: String]] = []
		if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
		messages.append(["role": "user", "content": prompt])

		var payload: [String: Any] = ["model": resolvedModel, "messages": messages]
		if let maxTokens { payload["max_tokens"] = maxTokens }

		var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if let key = apiKeyProvider(), !key.isEmpty {
			request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: payload)

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			throw LocalLLMError.unavailable
		}

		guard let http = response as? HTTPURLResponse else { throw LocalLLMError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw LocalLLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}

		guard let content = Self.parseContent(data), !content.isEmpty else { throw LocalLLMError.empty }
		return content
	}

	private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

	// MARK: - Helpers

	static func parseContent(_ data: Data) -> String? {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let choices = object["choices"] as? [[String: Any]],
			let message = choices.first?["message"] as? [String: Any],
			let content = message["content"] as? String
		else { return nil }
		return content.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Mirrors the backend `llm` handler's template syntax for the subset v1 uses.
	static func interpolate(_ template: String, input: String, stepOutputs: [String]) -> String {
		var result = template.replacingOccurrences(of: "{{input}}", with: input)
		for (index, output) in stepOutputs.enumerated() {
			result = result.replacingOccurrences(of: "{{steps[\(index)].output}}", with: output)
		}
		return result
	}
}
