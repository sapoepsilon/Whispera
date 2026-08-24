// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaOpenAI

/// The upload-a-whole-recording conformer, against the configured speech server.
///
/// It exists so a batch engine is reached through the same interface as
/// WhisperKit rather than through a `switch` in the caller. Everything below
/// the interface — the multipart builder, the WAV encoder, the mimetype map,
/// the retry policy — is `WhisperaOpenAI`, so this file is an adapter and
/// nothing else.
///
/// WHI-92: the endpoint used to be `https://api.openai.com/v1/audio/transcriptions`,
/// pinned as an initialiser default that nothing overrode, which made the whole
/// engine OpenAI-only by accident and unreachable for speaches, whisper.cpp or
/// LM Studio. It now reads the same `ServerEntry` the direct streaming engine
/// does — one address for one capability. See WHI-42, WHI-58.
@MainActor
final class RemoteBatchTranscriber: SpeechTranscribing {
	static let byok = RemoteBatchTranscriber()

	nonisolated var engine: TranscriptionEngine { .whisperViaBYOK }

	/// No streaming: the endpoint takes one finished recording. No managed
	/// models either — the model lives on the server's side.
	nonisolated var capabilities: TranscriptionCapabilities {
		[.fileTranscription, .bufferTranscription]
	}

	var onLiveAudioSamples: (@MainActor ([Float]) -> Void)?

	private let entryProvider: () -> ServerEntry
	private let session: URLSession

	init(
		entryProvider: @escaping () -> ServerEntry = { WhisperaSettings.speechServer },
		session: URLSession = .shared
	) {
		self.entryProvider = entryProvider
		self.session = session
	}

	private func client() throws -> OpenAICompatibleClient {
		let entry = entryProvider()
		guard let url = entry.url else { throw RemoteBatchTranscriberError.noServerConfigured }
		return OpenAICompatibleClient(
			baseURL: url, apiKeyProvider: entry.keyProvider, session: session, logger: .whispera)
	}

	var state: TranscriptionEngineState {
		guard entryProvider().url != nil else {
			return .unavailable(RemoteBatchTranscriberError.noServerConfigured.errorDescription ?? "")
		}
		return .ready
	}

	func prepare() async throws { _ = try client() }

	var activeModel: String? {
		let model = entryProvider().model
		return model.isEmpty ? nil : model
	}

	/// Ask the server what it can transcribe rather than echoing back the one
	/// string the user typed — the same listing the direct streaming engine and
	/// the Settings model picker use (WHI-93).
	func models() async throws -> [TranscriptionModelInfo] {
		try await client().transcriptionModels().map { TranscriptionModelInfo(id: $0.id) }
	}

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String {
		try await run(payload: try AudioPayload.file(at: url), options: options)
	}

	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
		guard !samples.isEmpty else { return "No audio data provided" }
		return try await run(payload: AudioPayload.wav(samples: samples), options: options)
	}

	/// One upload path, not two. `RemoteTranscriber` used to carry
	/// `transcribeViaWhispera` and `transcribeViaBYOK` — same wire format, same
	/// multipart builder, same `perform()`, differing only in URL and auth
	/// header (WHI-92).
	private func run(payload: AudioPayload, options: TranscriptionOptions) async throws -> String {
		// `capabilities` does not advertise translation and this stays a loud
		// refusal rather than quietly becoming a second endpoint: the package can
		// translate, but turning a request the engine used to reject into one it
		// now serves is a behaviour change this ticket has no mandate for.
		guard options.mode == .transcribe else {
			throw TranscriptionEngineError.unsupported(
				engine: engine.displayName, capability: "translate")
		}
		let entry = entryProvider()
		guard !entry.model.isEmpty else { throw RemoteBatchTranscriberError.noModelConfigured }
		let request = TranscriptionRequest(
			model: entry.model, audio: payload, language: options.language)
		return try await client().transcribe(request).text
	}
}

enum RemoteBatchTranscriberError: LocalizedError, Equatable {
	case noServerConfigured
	case noModelConfigured

	var errorDescription: String? {
		switch self {
		case .noServerConfigured:
			return "No speech server configured — add one under Settings → Servers."
		case .noModelConfigured:
			return "No transcription model set for the speech server. Refresh the model list in Settings → Servers."
		}
	}
}
