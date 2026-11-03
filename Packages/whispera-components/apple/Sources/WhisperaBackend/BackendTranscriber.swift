import Foundation
import WhisperaDictation
import WhisperaOpenAI

private struct TranscribeResponse: Decodable {
	let text: String
}

/// `POST /transcribe` — a whole recording, uploaded to the backend, which holds
/// the engine's address and key.
///
/// The multipart encoding comes from `WhisperaOpenAI` rather than being written
/// again here. There is one wire format, so there is one encoder; the version
/// this replaced had two implementations of it in one file.
public struct BackendTranscriber: Sendable {
	private let api: WhisperaAPIClient
	private let session: URLSession
	private let credentials: any DictationCredentialProvider
	private let baseURLProvider: @Sendable () -> URL?

	public init(
		baseURLProvider: @escaping @Sendable () -> URL?,
		credentials: any DictationCredentialProvider,
		session: URLSession = .shared
	) {
		self.baseURLProvider = baseURLProvider
		self.credentials = credentials
		self.session = session
		self.api = WhisperaAPIClient(
			baseURLProvider: baseURLProvider, credentials: credentials, session: session)
	}

	public func transcribe(audio: AudioPayload, language: String? = nil) async throws -> String {
		var form = MultipartFormData()
		if let language { form.addField(name: "language", value: language) }
		form.addFile(
			name: "file", filename: audio.filename, mimetype: audio.mimetype, data: audio.data)

		var request = try await api.authorizedRequest(path: "/transcribe", method: "POST")
		request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
		request.httpBody = form.encoded()

		let data = try await api.execute(request)
		let decoded: TranscribeResponse = try api.decode(data)
		guard !decoded.text.isEmpty else { throw WhisperaAPIError.empty }
		return decoded.text
	}

	public func transcribe(samples: [Float], language: String? = nil) async throws -> String {
		try await transcribe(audio: .wav(samples: samples), language: language)
	}

	public func transcribe(fileAt url: URL, language: String? = nil) async throws -> String {
		try await transcribe(audio: try .file(at: url), language: language)
	}
}
