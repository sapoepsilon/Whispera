// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where speech-to-text runs. Identity only — what each engine can do lives on
/// the conformer as `TranscriptionCapabilities`, so adding a case never reopens
/// a switch anywhere but here. WhisperKit stays the default (on-device, no
/// network). See WHI-42, WHI-58.
enum TranscriptionEngine: String, CaseIterable, Sendable {
	case whisperKit
	case whisperViaBYOK
	case whisperaStreaming

	var displayName: String {
		switch self {
		case .whisperKit: return "WhisperKit (on-device)"
		case .whisperViaBYOK: return "OpenAI Whisper via your key"
		case .whisperaStreaming: return "Whispera server (streaming)"
		}
	}
}

extension WhisperaSettings {
	private static let engineKey = "whisperaTranscriptionEngine"
	private static let transcriptionServerURLKey = "whisperaTranscriptionServerURL"
	private static let transcriptionServerIdKey = "whisperaTranscriptionServerId"

	/// Unknown raw values fall back to WhisperKit, so a persisted engine from a
	/// build that had one we no longer ship degrades on-device instead of
	/// trapping. Mirrors `llmMode`.
	static var transcriptionEngine: TranscriptionEngine {
		get {
			TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "")
				?? .whisperKit
		}
		set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
	}

	/// Base URL of the transcription backend. Separate from `serverURLString`
	/// because the streaming proxy can live somewhere other than the account
	/// backend; empty means "use the account backend".
	static var transcriptionServerURLString: String {
		get {
			let stored = UserDefaults.standard.string(forKey: transcriptionServerURLKey) ?? ""
			return stored.isEmpty ? serverURLString : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: transcriptionServerURLKey) }
	}

	static var transcriptionServerURL: URL? {
		URL(string: transcriptionServerURLString.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	/// Which engine on that backend to stream through. Empty means "let the
	/// backend's own `/transcription/servers` listing pick its default".
	static var transcriptionServerId: String {
		get { UserDefaults.standard.string(forKey: transcriptionServerIdKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: transcriptionServerIdKey) }
	}
}

/// Resolves the selected engine and hands back the conformer that runs it.
/// Mirrors `RecipeRouter`.
///
/// The conformers are shared instances rather than freshly built ones: a
/// streaming engine holds a live socket and a local engine holds a loaded
/// model, so both have to outlive a single call.
@MainActor
struct TranscriptionRouter {
	static let shared = TranscriptionRouter()

	private let engineProvider: () -> TranscriptionEngine

	init(engineProvider: @escaping () -> TranscriptionEngine = { WhisperaSettings.transcriptionEngine })
	{
		self.engineProvider = engineProvider
	}

	var selected: TranscriptionEngine { engineProvider() }

	var active: SpeechTranscribing { Self.transcriber(for: engineProvider()) }

	static func transcriber(for engine: TranscriptionEngine) -> SpeechTranscribing {
		switch engine {
		case .whisperKit:
			return WhisperKitTranscriber.shared
		case .whisperViaBYOK:
			return RemoteBatchTranscriber.byok
		case .whisperaStreaming:
			return StreamingTranscriber.shared
		}
	}
}
