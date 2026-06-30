// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where speech-to-text runs. WhisperKit stays the default (on-device, no
/// network). See WHI-42.
enum TranscriptionEngine: String, CaseIterable, Sendable {
	case whisperKit
	case whisperViaWhispera
	case whisperViaBYOK

	var displayName: String {
		switch self {
		case .whisperKit: return "WhisperKit (on-device)"
		case .whisperViaWhispera: return "OpenAI Whisper via Whispera"
		case .whisperViaBYOK: return "OpenAI Whisper via your key"
		}
	}
}

extension WhisperaSettings {
	private static let engineKey = "whisperaTranscriptionEngine"

	static var transcriptionEngine: TranscriptionEngine {
		get { TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .whisperKit }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
	}
}

enum RemoteTranscriberError: LocalizedError {
	case notSignedIn
	case missingOpenAIKey
	case invalidServerURL
	case http(status: Int, body: String)
	case empty
	case transport(Error)

	var errorDescription: String? {
		switch self {
		case .notSignedIn: return "Whisper-via-Whispera needs you to sign in (Account settings)."
		case .missingOpenAIKey: return "No OpenAI key saved. Add one in BYOK settings."
		case .invalidServerURL: return "Invalid Whispera server URL"
		case .http(let status, let body):
			return "Transcription failed (HTTP \(status))\(body.isEmpty ? "" : ": \(body)")"
		case .empty: return "Transcription returned no text."
		case .transport(let err): return "Network error: \(err.localizedDescription)"
		}
	}
}

private struct TranscribeResponse: Decodable {
	let text: String
}

private struct OpenAITranscribeResponse: Decodable {
	let text: String
}

/// Uploads recorded audio to a remote Whisper endpoint. Used for the two
/// non-WhisperKit engines. Never silently falls back to WhisperKit — failures
/// surface to the caller (WHI-42).
struct RemoteTranscriber {
	private let session: URLSession
	private let tokenStore: AuthTokenStore
	private let keyStore: ByokKeyStore
	private let serverURLProvider: () -> URL?
	private let openAITranscribeURL: URL

	init(
		session: URLSession = .shared,
		tokenStore: AuthTokenStore = .shared,
		keyStore: ByokKeyStore = .shared,
		serverURLProvider: @escaping () -> URL? = { WhisperaSettings.serverURL },
		openAITranscribeURL: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
	) {
		self.session = session
		self.tokenStore = tokenStore
		self.keyStore = keyStore
		self.serverURLProvider = serverURLProvider
		self.openAITranscribeURL = openAITranscribeURL
	}

	/// POSTs multipart audio to the Whispera backend `/transcribe` (Bearer auth).
	func transcribeViaWhispera(audio: Data, filename: String, mimetype: String, language: String?)
		async throws -> String
	{
		guard let base = serverURLProvider() else { throw RemoteTranscriberError.invalidServerURL }
		guard let token = try? tokenStore.load(), !token.isEmpty else {
			throw RemoteTranscriberError.notSignedIn
		}

		var fields: [String: String] = [:]
		if let language { fields["language"] = language }
		let (body, contentType) = Self.multipart(
			fileField: "file", filename: filename, mimetype: mimetype, fileData: audio, fields: fields)

		var request = URLRequest(url: base.appendingPathComponent("transcribe"))
		request.httpMethod = "POST"
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		request.httpBody = body

		let data = try await perform(request)
		let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
		guard !decoded.text.isEmpty else { throw RemoteTranscriberError.empty }
		return decoded.text
	}

	/// POSTs multipart audio directly to OpenAI using the user's key. The backend
	/// is never involved, so the key only reaches the user's own provider.
	/// `model` defaults to OpenAI's `whisper-1`; override for a custom
	/// OpenAI-compatible endpoint that names its model differently.
	func transcribeViaBYOK(
		audio: Data, filename: String, mimetype: String, language: String?, model: String = "whisper-1"
	) async throws -> String {
		guard let key = try keyStore.load(provider: .openai), !key.isEmpty else {
			throw RemoteTranscriberError.missingOpenAIKey
		}

		var fields: [String: String] = ["model": model]
		if let language { fields["language"] = language }
		let (body, contentType) = Self.multipart(
			fileField: "file", filename: filename, mimetype: mimetype, fileData: audio, fields: fields)

		var request = URLRequest(url: openAITranscribeURL)
		request.httpMethod = "POST"
		request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		request.httpBody = body

		let data = try await perform(request)
		let decoded = try JSONDecoder().decode(OpenAITranscribeResponse.self, from: data)
		guard !decoded.text.isEmpty else { throw RemoteTranscriberError.empty }
		return decoded.text
	}

	private func perform(_ request: URLRequest) async throws -> Data {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			throw RemoteTranscriberError.transport(error)
		}
		guard let http = response as? HTTPURLResponse else { throw RemoteTranscriberError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw RemoteTranscriberError.http(
				status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}
		return data
	}

	/// Builds a `multipart/form-data` body: one file part plus text fields.
	static func multipart(
		fileField: String, filename: String, mimetype: String, fileData: Data, fields: [String: String]
	) -> (Data, String) {
		let boundary = "whispera.\(UUID().uuidString)"
		var body = Data()
		let crlf = "\r\n"

		for (name, value) in fields {
			body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
			body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
			body.append("\(value)\(crlf)".data(using: .utf8)!)
		}

		body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
		body.append(
			"Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(crlf)".data(
				using: .utf8)!)
		body.append("Content-Type: \(mimetype)\(crlf)\(crlf)".data(using: .utf8)!)
		body.append(fileData)
		body.append(crlf.data(using: .utf8)!)
		body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

		return (body, "multipart/form-data; boundary=\(boundary)")
	}
}
