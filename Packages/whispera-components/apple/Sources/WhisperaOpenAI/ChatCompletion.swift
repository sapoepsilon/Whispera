import Foundation

public enum ChatRole: String, Codable, Sendable, Equatable {
	case system
	case user
	case assistant
}

public struct ChatMessage: Codable, Sendable, Equatable {
	public var role: ChatRole
	public var content: String

	public init(role: ChatRole, content: String) {
		self.role = role
		self.content = content
	}

	public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
	public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
	public static func assistant(_ content: String) -> ChatMessage {
		.init(role: .assistant, content: content)
	}
}

/// A `POST /chat/completions` body.
///
/// `temperature` is on here and is actually sent — it was accepted and dropped
/// on the floor in the app's copy, which made every recipe that set one behave
/// as if it had not.
public struct ChatCompletionRequest: Sendable, Equatable {
	public var model: String
	public var messages: [ChatMessage]
	public var temperature: Double?
	public var maxTokens: Int?
	public var stop: [String]?

	public init(
		model: String,
		messages: [ChatMessage],
		temperature: Double? = nil,
		maxTokens: Int? = nil,
		stop: [String]? = nil
	) {
		self.model = model
		self.messages = messages
		self.temperature = temperature
		self.maxTokens = maxTokens
		self.stop = stop
	}

	/// The single-turn shape recipes use.
	public init(
		model: String,
		system: String?,
		prompt: String,
		temperature: Double? = nil,
		maxTokens: Int? = nil
	) {
		var messages: [ChatMessage] = []
		if let system, !system.isEmpty { messages.append(.system(system)) }
		messages.append(.user(prompt))
		self.init(
			model: model, messages: messages, temperature: temperature, maxTokens: maxTokens)
	}

	/// Hand-rolled rather than derived from `CodingKeys`, because `stream` is not
	/// a property of the request the caller builds — it is a property of which
	/// method they called — and because an encoder that emits `"temperature":null`
	/// makes some OpenAI-compatible servers reject the whole body.
	func encodedBody(stream: Bool) throws -> Data {
		var payload: [String: Any] = [
			"model": model,
			"messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
		]
		if let temperature { payload["temperature"] = temperature }
		if let maxTokens { payload["max_tokens"] = maxTokens }
		if let stop, !stop.isEmpty { payload["stop"] = stop }
		if stream { payload["stream"] = true }
		return try JSONSerialization.data(withJSONObject: payload)
	}
}

public struct ChatCompletion: Sendable, Equatable, Decodable {
	public struct Choice: Sendable, Equatable, Decodable {
		public struct Message: Sendable, Equatable, Decodable {
			public let role: String?
			public let content: String?
		}
		public let index: Int?
		public let message: Message?
		public let finishReason: String?

		enum CodingKeys: String, CodingKey {
			case index, message
			case finishReason = "finish_reason"
		}
	}

	public let id: String?
	public let model: String?
	public let choices: [Choice]

	/// The first choice's content, trimmed. Nil rather than empty when there is
	/// nothing usable, so a caller cannot mistake "the model said nothing" for
	/// "the model said the empty string".
	public var text: String? {
		guard let content = choices.first?.message?.content else { return nil }
		let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// Tolerates the shape rather than the schema: some OpenAI-compatible servers
	/// omit `id` or `model` entirely, and refusing those would refuse a working
	/// completion over a field nothing reads.
	public static func text(from data: Data) -> String? {
		(try? JSONDecoder().decode(ChatCompletion.self, from: data))?.text
	}
}

/// One `stream: true` chunk, reduced to what a caller actually consumes.
public struct ChatStreamEvent: Sendable, Equatable {
	/// The new text in this chunk. Empty on the chunk that only carries a role
	/// or a finish reason.
	public let delta: String
	public let finishReason: String?

	public init(delta: String, finishReason: String? = nil) {
		self.delta = delta
		self.finishReason = finishReason
	}
}

struct ChatCompletionChunk: Decodable {
	struct Choice: Decodable {
		struct Delta: Decodable {
			let role: String?
			let content: String?
		}
		let delta: Delta?
		let finishReason: String?

		enum CodingKeys: String, CodingKey {
			case delta
			case finishReason = "finish_reason"
		}
	}
	let choices: [Choice]

	var event: ChatStreamEvent {
		ChatStreamEvent(
			delta: choices.first?.delta?.content ?? "",
			finishReason: choices.first?.finishReason)
	}
}
