import Foundation

#if canImport(FoundationNetworking)
	import FoundationNetworking
#endif

public struct OpenAIClientConfiguration: Sendable, Equatable {
	/// A recipe runs while the user watches a HUD. URLSession's default 60s would
	/// leave them staring at a spinner for a minute before any fallback; 20s is
	/// long enough for a server to return a full non-streamed completion for
	/// prompt-sized input, and short enough that a dead hop fails while the user
	/// is still looking. Worst case with the one retry: ~41s, still under a
	/// single default timeout.
	public var timeout: TimeInterval
	/// Streaming holds the socket open for as long as the model keeps talking, so
	/// the non-streaming budget is the wrong number for it.
	public var streamingTimeout: TimeInterval
	/// Backoff before the single retry — enough for a sleeping proxy or a dropped
	/// route to come back, short enough not to add a visible stall.
	public var retryDelayNanoseconds: UInt64
	/// One retry, or none. Never more: a second retry doubles the wait a user is
	/// already sitting through, for a case that has already failed twice.
	public var retriesOnce: Bool

	public init(
		timeout: TimeInterval = 20,
		streamingTimeout: TimeInterval = 120,
		retryDelayNanoseconds: UInt64 = 1_000_000_000,
		retriesOnce: Bool = true
	) {
		self.timeout = timeout
		self.streamingTimeout = streamingTimeout
		self.retryDelayNanoseconds = retryDelayNanoseconds
		self.retriesOnce = retriesOnce
	}
}

/// One client for every OpenAI-compatible server.
///
/// "Local" and "bring your own key" are not two things: they are this type with
/// a different base URL and a different bearer. Anthropic is a third base URL.
/// Keeping that as one code path is the whole point — the alternative is three
/// clients that drift, and a provider enum that has to be reopened every time
/// someone stands up a new endpoint.
public struct OpenAICompatibleClient: Sendable {
	public let baseURL: URL
	private let apiKeyProvider: @Sendable () -> String?
	private let session: URLSession
	private let configuration: OpenAIClientConfiguration
	private let logger: OpenAILogger

	public init(
		baseURL: URL,
		apiKey: String? = nil,
		session: URLSession = .shared,
		configuration: OpenAIClientConfiguration = OpenAIClientConfiguration(),
		logger: OpenAILogger = .none
	) {
		self.init(
			baseURL: baseURL, apiKeyProvider: { apiKey }, session: session,
			configuration: configuration, logger: logger)
	}

	/// The key as a closure rather than a string, for the shape the Keychain
	/// wants: read at request time and dropped afterwards, so a key that was
	/// rotated between two calls is not still in flight on the second.
	public init(
		baseURL: URL,
		apiKeyProvider: @escaping @Sendable () -> String?,
		session: URLSession = .shared,
		configuration: OpenAIClientConfiguration = OpenAIClientConfiguration(),
		logger: OpenAILogger = .none
	) {
		self.baseURL = baseURL
		self.apiKeyProvider = apiKeyProvider
		self.session = session
		self.configuration = configuration
		self.logger = logger
	}

	// MARK: - Chat completions

	public func chat(_ request: ChatCompletionRequest) async throws -> ChatCompletion {
		guard !request.model.isEmpty else { throw OpenAIError.noModel }

		let urlRequest = try jsonRequest(
			path: "chat/completions",
			body: request.encodedBody(stream: false),
			timeout: configuration.timeout)
		let data = try await performExpectingBody(urlRequest)

		do {
			return try JSONDecoder().decode(ChatCompletion.self, from: data)
		} catch {
			throw OpenAIError.decoding("\(error)")
		}
	}

	/// The one-string convenience the recipe pipeline runs on.
	public func complete(
		system: String?,
		prompt: String,
		model: String,
		temperature: Double? = nil,
		maxTokens: Int? = nil
	) async throws -> String {
		let completion = try await chat(
			ChatCompletionRequest(
				model: model, system: system, prompt: prompt, temperature: temperature,
				maxTokens: maxTokens))
		guard let text = completion.text else { throw OpenAIError.empty }
		return text
	}

	/// `stream: true`, parsed off the byte stream as it arrives.
	///
	/// The retry policy deliberately does not apply: a stream that dies after its
	/// first token cannot be replayed from the start without showing the user the
	/// same words twice, so a mid-stream failure is surfaced instead.
	public func streamChat(
		_ request: ChatCompletionRequest
	) -> AsyncThrowingStream<ChatStreamEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					guard !request.model.isEmpty else { throw OpenAIError.noModel }
					let urlRequest = try jsonRequest(
						path: "chat/completions",
						body: request.encodedBody(stream: true),
						timeout: configuration.streamingTimeout)

					let (bytes, response) = try await bytes(for: urlRequest)
					try await checkStreamStatus(response, bytes: bytes)

					var parser = SSEParser()
					for try await byte in bytes {
						guard let event = parser.consume(byte) else { continue }
						if emit(event, to: continuation) != nil {
							continuation.finish()
							return
						}
					}
					for event in parser.finish() where emit(event, to: continuation) != nil {
						break
					}
					continuation.finish()
				} catch is CancellationError {
					continuation.finish(throwing: CancellationError())
				} catch let error as URLError where error.code == .cancelled {
					continuation.finish(throwing: CancellationError())
				} catch let error as OpenAIError {
					continuation.finish(throwing: error)
				} catch let error as URLError {
					continuation.finish(
						throwing: OpenAIError.unreachable(
							url: baseURL.absoluteString,
							reason: OpenAITransportRetryPolicy.shortReason(for: error),
							retried: false))
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Just the text, for a caller that wants to append deltas and nothing else.
	public func streamChatText(
		_ request: ChatCompletionRequest
	) -> AsyncThrowingStream<String, Error> {
		let events = streamChat(request)
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await event in events where !event.delta.isEmpty {
						continuation.yield(event.delta)
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Returns non-nil once the stream is over, so the caller stops reading.
	private func emit(
		_ event: SSEEvent, to continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
	) -> Bool? {
		// The sentinel is the server saying it is done; it is not JSON, and
		// decoding it would look like a malformed chunk.
		guard event.data != "[DONE]" else { return true }
		guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: Data(event.data.utf8))
		else { return nil }
		continuation.yield(chunk.event)
		return nil
	}

	// MARK: - Models

	/// `GET {base}/models`.
	///
	/// A multi-purpose host serves LLMs, embeddings and speech models from one
	/// endpoint, so `task` narrows the list to the ones that can do the job being
	/// asked about. An answering server with nothing usable is its own failure —
	/// worth a different sentence than one that cannot be reached.
	public func models(task: String? = nil) async throws -> [OpenAIModel] {
		struct Response: Decodable { let data: [OpenAIModel] }

		let data = try await performExpectingBody(
			plainRequest(path: "models", timeout: configuration.timeout))

		let decoded: Response
		do {
			decoded = try JSONDecoder().decode(Response.self, from: data)
		} catch {
			throw OpenAIError.decoding("\(error)")
		}

		guard let task else { return decoded.data }
		let matching = decoded.data.filter { $0.task == task }
		guard !matching.isEmpty else { throw OpenAIError.noModelsAvailable(destination) }
		return matching
	}

	/// The models this server can transcribe with.
	public func transcriptionModels() async throws -> [OpenAIModel] {
		try await models(task: OpenAIModel.speechRecognitionTask)
	}

	// MARK: - Audio

	public func transcribe(_ request: TranscriptionRequest) async throws -> Transcription {
		try await upload(request, to: "audio/transcriptions")
	}

	/// Transcription and translation are two endpoints on the same server, not a
	/// flag — asking the transcription endpoint to translate returns the original
	/// language and looks like a success.
	public func translate(_ request: TranscriptionRequest) async throws -> Transcription {
		try await upload(request, to: "audio/translations")
	}

	private func upload(_ request: TranscriptionRequest, to path: String) async throws
		-> Transcription
	{
		guard !request.model.isEmpty else { throw OpenAIError.noModel }

		var form = MultipartFormData()
		form.addFields(request.fields())
		form.addFile(
			name: "file",
			filename: request.audio.filename,
			mimetype: request.audio.mimetype,
			data: request.audio.data)

		var urlRequest = URLRequest(url: url(for: path))
		urlRequest.httpMethod = "POST"
		urlRequest.timeoutInterval = configuration.timeout
		urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
		authorize(&urlRequest)
		urlRequest.httpBody = form.encoded()

		let data = try await performExpectingBody(urlRequest)
		let decoded: Transcription
		do {
			decoded = try JSONDecoder().decode(Transcription.self, from: data)
		} catch {
			throw OpenAIError.decoding("\(error)")
		}
		guard !decoded.text.isEmpty else { throw OpenAIError.empty }
		return decoded
	}

	// MARK: - Transport

	private var destination: String { baseURL.host ?? baseURL.absoluteString }

	/// String join rather than `appendingPathComponent`, so a base URL that
	/// already carries a query (a proxy keyed by parameter) is not mangled into
	/// the path.
	private func url(for path: String) -> URL {
		let trimmed =
			baseURL.absoluteString.hasSuffix("/")
			? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
		return URL(string: trimmed + "/" + path) ?? baseURL.appendingPathComponent(path)
	}

	private func authorize(_ request: inout URLRequest) {
		guard let key = apiKeyProvider(), !key.isEmpty else { return }
		request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
	}

	private func plainRequest(path: String, timeout: TimeInterval) -> URLRequest {
		var request = URLRequest(url: url(for: path))
		request.timeoutInterval = timeout
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		authorize(&request)
		return request
	}

	private func jsonRequest(path: String, body: Data, timeout: TimeInterval) throws -> URLRequest {
		var request = plainRequest(path: path, timeout: timeout)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = body
		return request
	}

	private func performExpectingBody(_ request: URLRequest) async throws -> Data {
		let (data, response) = try await send(request)
		guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw OpenAIError.http(
				status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}
		return data
	}

	/// One bounded retry on transient transport failures. HTTP error statuses
	/// never reach here — the server answered, so the caller reports them as-is.
	/// The wording says "model server", not "local": the configured endpoint may
	/// be a proxy on another machine.
	private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
		do {
			return try await session.data(for: request)
		} catch {
			let urlError = error as? URLError
			if urlError?.code == .cancelled { throw CancellationError() }
			guard configuration.retriesOnce, let urlError,
				OpenAITransportRetryPolicy.shouldRetry(urlError.code)
			else {
				let reason =
					urlError.map { OpenAITransportRetryPolicy.shortReason(for: $0) }
					?? error.localizedDescription
				logger.error("Model server request to \(destination) failed, not retryable: \(reason)")
				throw OpenAIError.unreachable(
					url: baseURL.absoluteString, reason: reason, retried: false)
			}

			logger.info(
				"Model server request to \(destination) failed (\(OpenAITransportRetryPolicy.shortReason(for: urlError))); retrying once"
			)
			try? await Task.sleep(nanoseconds: configuration.retryDelayNanoseconds)
			try Task.checkCancellation()
			do {
				return try await session.data(for: request)
			} catch {
				if (error as? URLError)?.code == .cancelled { throw CancellationError() }
				let reason =
					(error as? URLError).map { OpenAITransportRetryPolicy.shortReason(for: $0) }
					?? error.localizedDescription
				logger.error("Model server request to \(destination) failed again after retry: \(reason)")
				throw OpenAIError.unreachable(
					url: baseURL.absoluteString, reason: reason, retried: true)
			}
		}
	}

	private func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
		try await session.bytes(for: request)
	}

	/// A streamed error body still has to be read before it can be reported, and
	/// it arrives as bytes like everything else.
	private func checkStreamStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
		guard let http = response as? HTTPURLResponse else { throw OpenAIError.empty }
		guard !(200..<300).contains(http.statusCode) else { return }
		var body = Data()
		for try await byte in bytes {
			body.append(byte)
			if body.count > 8192 { break }
		}
		throw OpenAIError.http(
			status: http.statusCode, body: String(data: body, encoding: .utf8) ?? "")
	}
}

public struct OpenAIModel: Sendable, Equatable, Decodable {
	public static let speechRecognitionTask = "automatic-speech-recognition"

	public let id: String
	/// What the model is for, on servers that say. Absent on OpenAI itself.
	public let task: String?
	public let object: String?
	public let ownedBy: String?

	enum CodingKeys: String, CodingKey {
		case id, task, object
		case ownedBy = "owned_by"
	}

	public init(id: String, task: String? = nil, object: String? = nil, ownedBy: String? = nil) {
		self.id = id
		self.task = task
		self.object = object
		self.ownedBy = ownedBy
	}
}
