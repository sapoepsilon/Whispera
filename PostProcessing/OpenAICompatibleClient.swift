import Foundation

protocol TextPostProcessor: Sendable {
	func process(_ messages: PostProcessingMessages) async throws -> String
}

enum PostProcessingError: LocalizedError, Equatable {
	case invalidBaseURL(String)
	case missingAPIKey(provider: String)
	case missingModel(provider: String)
	case httpStatus(code: Int, message: String)
	case emptyResponse
	case malformedResponse
	case appleIntelligenceUnavailable(reason: String)

	var errorDescription: String? {
		switch self {
		case .invalidBaseURL(let url):
			return "Invalid base URL: \(url)"
		case .missingAPIKey(let provider):
			return "No API key saved for \(provider)"
		case .missingModel(let provider):
			return "No model selected for \(provider)"
		case .httpStatus(let code, let message):
			return "Provider returned HTTP \(code): \(message)"
		case .emptyResponse:
			return "Provider returned no text"
		case .malformedResponse:
			return "Provider response could not be decoded"
		case .appleIntelligenceUnavailable(let reason):
			return "Apple Intelligence is unavailable: \(reason)"
		}
	}
}

/// Minimal client for the OpenAI chat-completions wire format, which OpenAI, OpenRouter, Groq,
/// Cerebras, Z.AI, Anthropic's compatibility endpoint, Bedrock Mantle, Ollama and LM Studio all accept.
struct OpenAICompatibleClient: TextPostProcessor {
	let baseURL: String
	let apiKey: String?
	let model: String
	let timeout: TimeInterval
	let session: URLSession

	init(
		baseURL: String, apiKey: String?, model: String, timeout: TimeInterval = 30,
		session: URLSession = .shared
	) {
		self.baseURL = baseURL
		self.apiKey = apiKey
		self.model = model
		self.timeout = timeout
		self.session = session
	}

	func process(_ messages: PostProcessingMessages) async throws -> String {
		let raw = try await chatCompletion(systemPrompt: messages.system, userMessage: messages.user)
		let cleaned = PostProcessingText.cleanModelOutput(raw)
		guard !cleaned.isEmpty else { throw PostProcessingError.emptyResponse }
		return cleaned
	}

	func chatCompletion(systemPrompt: String?, userMessage: String) async throws -> String {
		var messages: [ChatMessage] = []
		if let systemPrompt, !systemPrompt.isEmpty {
			messages.append(ChatMessage(role: "system", content: systemPrompt))
		}
		messages.append(ChatMessage(role: "user", content: userMessage))

		var request = try makeRequest(path: "chat/completions", method: "POST")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(
			ChatRequest(model: model, messages: messages, stream: false))

		let data = try await send(request)
		guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
			throw PostProcessingError.malformedResponse
		}
		guard let content = response.choices.first?.message.content else {
			throw PostProcessingError.emptyResponse
		}
		return content
	}

	func listModels() async throws -> [String] {
		let request = try makeRequest(path: "models", method: "GET")
		let data = try await send(request)
		guard let response = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
			throw PostProcessingError.malformedResponse
		}
		return response.data.map(\.id).sorted()
	}

	static func endpoint(baseURL: String, path: String) -> URL? {
		var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		while base.hasSuffix("/") { base.removeLast() }
		guard let url = URL(string: "\(base)/\(path)"),
			let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
			url.host?.isEmpty == false
		else { return nil }
		return url
	}

	private func makeRequest(path: String, method: String) throws -> URLRequest {
		guard let url = Self.endpoint(baseURL: baseURL, path: path) else {
			throw PostProcessingError.invalidBaseURL(baseURL)
		}
		var request = URLRequest(url: url, timeoutInterval: timeout)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let apiKey, !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		}
		return request
	}

	private func send(_ request: URLRequest) async throws -> Data {
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else { throw PostProcessingError.malformedResponse }
		guard (200..<300).contains(http.statusCode) else {
			let message = Self.redacting(apiKey, in: Self.errorMessage(from: data))
			throw PostProcessingError.httpStatus(code: http.statusCode, message: message)
		}
		return data
	}

	/// Providers such as OpenAI echo a masked key in 401 messages; strip both the exact key and
	/// anything key-shaped so error alerts and logs never carry key material.
	static func redacting(_ apiKey: String?, in message: String) -> String {
		var result = message
		if let apiKey, !apiKey.isEmpty {
			result = result.replacingOccurrences(of: apiKey, with: "[redacted]")
		}
		return result.replacingOccurrences(
			of: #"\b(sk|gsk|csk|or|xai)-[A-Za-z0-9_\-\*\.]{4,}"#, with: "[redacted]",
			options: .regularExpression)
	}

	/// Surfaces the provider's own error text when it follows the OpenAI error shape, truncated so a
	/// verbose HTML error page does not flood the alert or the log.
	static func errorMessage(from data: Data) -> String {
		if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
			return String(envelope.error.message.prefix(300))
		}
		let text = String(decoding: data.prefix(300), as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? "no details" : text
	}
}

private struct ChatMessage: Codable {
	let role: String
	let content: String
}

private struct ChatRequest: Encodable {
	let model: String
	let messages: [ChatMessage]
	let stream: Bool
}

private struct ChatResponse: Decodable {
	struct Choice: Decodable {
		struct Message: Decodable {
			let content: String?
		}
		let message: Message
	}
	let choices: [Choice]
}

private struct ModelsResponse: Decodable {
	struct Model: Decodable {
		let id: String
	}
	let data: [Model]
}

private struct ErrorEnvelope: Decodable {
	struct Detail: Decodable {
		let message: String
	}
	let error: Detail
}
