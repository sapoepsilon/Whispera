import Foundation

/// A `POST /audio/transcriptions` (or `/audio/translations`) body.
public struct TranscriptionRequest: Sendable, Equatable {
	public var model: String
	public var audio: AudioPayload
	public var language: String?
	public var prompt: String?
	public var temperature: Double?
	/// `json`, `text`, `verbose_json`, … Left to the server's default when nil.
	public var responseFormat: String?

	public init(
		model: String,
		audio: AudioPayload,
		language: String? = nil,
		prompt: String? = nil,
		temperature: Double? = nil,
		responseFormat: String? = nil
	) {
		self.model = model
		self.audio = audio
		self.language = language
		self.prompt = prompt
		self.temperature = temperature
		self.responseFormat = responseFormat
	}

	func fields() -> [String: String] {
		var fields: [String: String] = ["model": model]
		if let language { fields["language"] = language }
		if let prompt { fields["prompt"] = prompt }
		if let temperature { fields["temperature"] = String(temperature) }
		if let responseFormat { fields["response_format"] = responseFormat }
		return fields
	}
}

public struct Transcription: Sendable, Equatable, Decodable {
	public let text: String
	public let language: String?
	public let duration: Double?
}
