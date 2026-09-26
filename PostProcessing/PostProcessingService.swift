import Foundation

enum PostProcessingOutcome: Equatable {
	case processed(String)
	case skipped(original: String)
	case failed(original: String, error: String)

	/// The text that should reach the user: never lose the transcript because the LLM failed.
	var text: String {
		switch self {
		case .processed(let text): return text
		case .skipped(let original), .failed(let original, _): return original
		}
	}
}

struct PostProcessingService {
	let settings: PostProcessingSettings
	let secrets: PostProcessingSecretStore
	let session: URLSession

	init(
		settings: PostProcessingSettings = PostProcessingSettings(),
		secrets: PostProcessingSecretStore = KeychainSecretStore(),
		session: URLSession = .shared
	) {
		self.settings = settings
		self.secrets = secrets
		self.session = session
	}

	func makeProcessor(for provider: PostProcessingProvider) throws -> TextPostProcessor {
		switch provider.kind {
		case .appleIntelligence:
			return AppleIntelligenceProcessor()
		case .openAICompatible:
			let model = settings.model(for: provider.id)
			guard !model.isEmpty else { throw PostProcessingError.missingModel(provider: provider.label) }
			let key = try secrets.apiKey(for: provider.id)
			if provider.requiresAPIKey, key?.isEmpty ?? true {
				throw PostProcessingError.missingAPIKey(provider: provider.label)
			}
			return OpenAICompatibleClient(
				baseURL: settings.baseURL(for: provider), apiKey: key, model: model,
				timeout: settings.timeoutSeconds, session: session)
		}
	}

	func process(_ transcript: String) async -> PostProcessingOutcome {
		guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return .skipped(original: transcript)
		}
		let provider = settings.provider
		let prompt = settings.selectedPrompt
		let logger = AppLogger.shared.general
		do {
			let processor = try makeProcessor(for: provider)
			let started = Date()
			let result = try await processor.process(prompt.messages(for: transcript))
			logger.info(
				"Post-processing via \(provider.id) with prompt '\(prompt.id)' took \(String(format: "%.2f", Date().timeIntervalSince(started)))s (\(transcript.count) -> \(result.count) chars)"
			)
			return .processed(result)
		} catch {
			// Error descriptions never include the API key: the client only echoes the provider's
			// own error message and HTTP status.
			logger.error("Post-processing via \(provider.id) failed: \(error.localizedDescription)")
			return .failed(original: transcript, error: error.localizedDescription)
		}
	}
}
