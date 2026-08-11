// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// The upload-a-whole-recording conformer, over the user's own OpenAI key.
///
/// It exists so the BYOK engine is reached through the same interface as
/// WhisperKit rather than through a `switch` in the caller. The HTTP work stays
/// in `RemoteTranscriber`, which is unchanged and still has its own tests; this
/// type only adapts it to `SpeechTranscribing`. See WHI-42, WHI-58.
@MainActor
final class RemoteBatchTranscriber: SpeechTranscribing {
	static let byok = RemoteBatchTranscriber()

	nonisolated var engine: TranscriptionEngine { .whisperViaBYOK }

	/// No streaming: the endpoint takes one finished recording. No managed
	/// models either — the model lives on the provider's side.
	nonisolated var capabilities: TranscriptionCapabilities {
		[.fileTranscription, .bufferTranscription]
	}

	var onLiveAudioSamples: (@MainActor ([Float]) -> Void)?

	private let remote: RemoteTranscriber
	private let keyStore: ByokKeyStore

	init(remote: RemoteTranscriber = RemoteTranscriber(), keyStore: ByokKeyStore = .shared) {
		self.remote = remote
		self.keyStore = keyStore
	}

	var state: TranscriptionEngineState {
		let key = try? keyStore.load(provider: .openai)
		guard let key, !key.isEmpty else {
			return .unavailable(RemoteTranscriberError.missingOpenAIKey.errorDescription ?? "")
		}
		return .ready
	}

	func prepare() async throws {
		guard let key = try keyStore.load(provider: .openai), !key.isEmpty else {
			throw RemoteTranscriberError.missingOpenAIKey
		}
	}

	var activeModel: String? { WhisperaSettings.byokTranscriptionModel }

	func models() async throws -> [TranscriptionModelInfo] {
		[TranscriptionModelInfo(id: WhisperaSettings.byokTranscriptionModel)]
	}

	func transcribe(fileAt url: URL, options: TranscriptionOptions) async throws -> String {
		try requireTranscribeOnly(options)
		let audio = try Data(contentsOf: url)
		return try await remote.transcribeViaBYOK(
			audio: audio,
			filename: url.lastPathComponent,
			mimetype: Self.mimetype(for: url),
			language: options.language,
			model: WhisperaSettings.byokTranscriptionModel)
	}

	func transcribe(samples: [Float], options: TranscriptionOptions) async throws -> String {
		try requireTranscribeOnly(options)
		guard !samples.isEmpty else { return "No audio data provided" }
		return try await remote.transcribeViaBYOK(
			audio: Self.wav(from: samples),
			filename: "dictation.wav",
			mimetype: "audio/wav",
			language: options.language,
			model: WhisperaSettings.byokTranscriptionModel)
	}

	/// OpenAI splits transcription and translation across two endpoints, so a
	/// translate request cannot be honoured here. It fails loudly rather than
	/// returning untranslated text that looks like a success.
	private func requireTranscribeOnly(_ options: TranscriptionOptions) throws {
		guard options.mode == .transcribe else {
			throw TranscriptionEngineError.unsupported(
				engine: engine.displayName, capability: "translate")
		}
	}

	private static func mimetype(for url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "mp3": return "audio/mpeg"
		case "m4a", "mp4": return "audio/mp4"
		case "flac": return "audio/flac"
		case "ogg": return "audio/ogg"
		case "webm": return "audio/webm"
		default: return "audio/wav"
		}
	}

	/// Wraps mono float samples in a 16-bit PCM WAV container. The upload
	/// endpoints want a file, and the capture path hands us a raw buffer.
	/// Nonisolated because the two-pass finalizer wraps up to ten minutes of
	/// audio off the main actor, where a per-sample loop has no business.
	nonisolated static func wav(from samples: [Float], sampleRate: Int = 16000) -> Data {
		let bitsPerSample = 16
		let channels = 1
		let byteRate = sampleRate * channels * bitsPerSample / 8
		let blockAlign = channels * bitsPerSample / 8
		let dataBytes = samples.count * bitsPerSample / 8

		var data = Data(capacity: 44 + dataBytes)
		func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func appendUInt32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
		func appendUInt16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

		appendASCII("RIFF")
		appendUInt32(36 + dataBytes)
		appendASCII("WAVE")
		appendASCII("fmt ")
		appendUInt32(16)
		appendUInt16(1)  // PCM
		appendUInt16(channels)
		appendUInt32(sampleRate)
		appendUInt32(byteRate)
		appendUInt16(blockAlign)
		appendUInt16(bitsPerSample)
		appendASCII("data")
		appendUInt32(dataBytes)

		for sample in samples {
			let clamped = max(-1.0, min(1.0, sample))
			let scaled = Int16(clamped * Float(Int16.max))
			withUnsafeBytes(of: scaled.littleEndian) { data.append(contentsOf: $0) }
		}

		return data
	}
}

extension WhisperaSettings {
	private static let byokTranscriptionModelKey = "whisperaByokTranscriptionModel"

	static let defaultByokTranscriptionModel = "whisper-1"

	/// Model name the BYOK transcription endpoint expects. Separate from
	/// `byokModel`, which names the chat model recipes run on.
	static var byokTranscriptionModel: String {
		get {
			let stored = UserDefaults.standard.string(forKey: byokTranscriptionModelKey) ?? ""
			return stored.isEmpty ? defaultByokTranscriptionModel : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: byokTranscriptionModelKey) }
	}
}
