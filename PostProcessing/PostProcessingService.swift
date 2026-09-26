import Foundation

enum PostProcessingOutcome: Equatable, Sendable {
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

/// One post-processing pass together with the prompt that drove it, so history can show what
/// was asked of the model next to what came back.
struct PostProcessingRun: Equatable, Sendable {
	let prompt: PostProcessingPrompt
	let outcome: PostProcessingOutcome
}

struct PostProcessingService {
	let settings: PostProcessingSettings
	let secrets: PostProcessingSecretStore
	let session: URLSession
	/// Replaces the provider's processor; tests use it to simulate hung or runaway models.
	let processorOverride: (@Sendable (PostProcessingProvider) throws -> TextPostProcessor)?

	init(
		settings: PostProcessingSettings = PostProcessingSettings(),
		secrets: PostProcessingSecretStore = KeychainSecretStore(),
		session: URLSession = .shared,
		processorOverride: (@Sendable (PostProcessingProvider) throws -> TextPostProcessor)? = nil
	) {
		self.settings = settings
		self.secrets = secrets
		self.session = session
		self.processorOverride = processorOverride
	}

	/// The model may rewrite, but a reply this much longer than the dictation is a loop or a
	/// chatty answer, and pasting tens of kilobytes into the user's document is worse than raw text.
	static func outputLimit(forTranscript transcript: String) -> Int {
		max(transcript.count * 5, 1000)
	}

	/// `URLRequest.timeoutInterval` only fires when no bytes arrive for that long, so a server that
	/// trickles a response, and the on-device model, which has no timeout, need a hard deadline.
	/// The caller is released at the deadline even when the operation ignores cancellation: a task
	/// group would wait for the child to finish before returning.
	static func withDeadline<T: Sendable>(
		seconds: Double, _ operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		let work = Task { try await operation() }
		let gate = ResumeOnce<T>()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				gate.set(continuation)
				let timer = Task {
					try? await Task.sleep(for: .seconds(seconds))
					guard !Task.isCancelled else { return }
					work.cancel()
					gate.resume(with: .failure(PostProcessingError.timedOut(seconds: Int(seconds.rounded(.up)))))
				}
				Task {
					let result = await work.result
					timer.cancel()
					gate.resume(with: result)
				}
			}
		} onCancel: {
			work.cancel()
			gate.resume(with: .failure(CancellationError()))
		}
	}

	func makeProcessor(for provider: PostProcessingProvider) throws -> TextPostProcessor {
		if let processorOverride {
			return try processorOverride(provider)
		}
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
				timeout: settings.timeoutSeconds, session: session,
				structuredOutput: provider.supportsStructuredOutput)
		}
	}

	func process(_ transcript: String) async -> PostProcessingOutcome {
		await run(transcript).outcome
	}

	func run(_ transcript: String) async -> PostProcessingRun {
		let prompt = settings.selectedPrompt
		return PostProcessingRun(prompt: prompt, outcome: await process(transcript, prompt: prompt))
	}

	private func process(_ transcript: String, prompt: PostProcessingPrompt) async -> PostProcessingOutcome {
		guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return .skipped(original: transcript)
		}
		let provider = settings.provider
		let logger = AppLogger.shared.general
		do {
			let processor = try makeProcessor(for: provider)
			let started = Date()
			let messages = prompt.messages(for: transcript)
			let result = try await Self.withDeadline(seconds: settings.timeoutSeconds) {
				try await processor.process(messages)
			}
			let limit = Self.outputLimit(forTranscript: transcript)
			guard result.count <= limit else {
				throw PostProcessingError.responseTooLong(characters: result.count, limit: limit)
			}
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

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<T, Error>?
	private var pending: Result<T, Error>?
	private var finished = false

	func set(_ continuation: CheckedContinuation<T, Error>) {
		lock.lock()
		if let pending {
			lock.unlock()
			continuation.resume(with: pending)
			return
		}
		self.continuation = continuation
		lock.unlock()
	}

	func resume(with result: Result<T, Error>) {
		lock.lock()
		guard !finished else {
			lock.unlock()
			return
		}
		finished = true
		guard let continuation else {
			// Cancelled before the continuation existed; hand the result over in set()
			pending = result
			lock.unlock()
			return
		}
		self.continuation = nil
		lock.unlock()
		continuation.resume(with: result)
	}
}
