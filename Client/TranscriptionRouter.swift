// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where speech-to-text runs. Identity only — what each engine can do lives on
/// the conformer as `TranscriptionCapabilities`, so adding a case never reopens
/// a switch anywhere but here. `auto` is the default for fresh installs: it
/// decides between the others itself, so nobody has to configure anything to
/// get the best path available. See WHI-42, WHI-58.
enum TranscriptionEngine: String, CaseIterable, Sendable {
	case auto
	case whisperKit
	case whisperViaBYOK
	case whisperaStreaming
	case realtimeDirect

	/// Whether the engine transcribes over a live socket to a server. These are the
	/// engines that need a URL, and the ones live transcription is worth turning on
	/// for — a server engine with it off records first and transcribes at the end,
	/// which looks like the feature is broken.
	///
	/// `auto` answers `false` even though it may end up streaming: it resolves to
	/// a *conformer* (`AutoTranscriber`) rather than to `StreamingTranscriber`
	/// itself, so it is not "the streaming conformer" the way the other two are —
	/// see `ServerEngineTests.everyServerEngineResolvesToTheStreamingConformer`.
	var streamsFromAServer: Bool {
		switch self {
		case .whisperaStreaming, .realtimeDirect: return true
		case .auto, .whisperKit, .whisperViaBYOK: return false
		}
	}

	var displayName: String {
		switch self {
		case .auto: return "Automatic (recommended)"
		case .whisperKit: return "WhisperKit (on-device)"
		case .whisperViaBYOK: return "OpenAI Whisper via your key"
		case .whisperaStreaming: return "Whispera server (streaming)"
		case .realtimeDirect: return "OpenAI-Realtime server (direct)"
		}
	}
}

extension WhisperaSettings {
	private static let engineKey = "whisperaTranscriptionEngine"
	private static let transcriptionServerURLKey = "whisperaTranscriptionServerURL"
	private static let transcriptionServerIdKey = "whisperaTranscriptionServerId"

	/// Unknown or absent raw values fall back to `auto` — a fresh install and a
	/// build that had an engine this one no longer ships land on the same
	/// default, which is honest because `auto` degrades to on-device itself
	/// whenever nothing is configured. Mirrors `llmMode`.
	static var transcriptionEngine: TranscriptionEngine {
		get {
			TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "")
				?? .auto
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
	/// The model to ask a directly-addressed engine for. Only consulted in
	/// `.realtimeDirect`: with no backend there is no `/transcription/servers`
	/// to name one, so the host has to.
	static var transcriptionDirectModel: String {
		get {
			let stored = UserDefaults.standard.string(forKey: "whisperaTranscriptionDirectModel") ?? ""
			return stored.isEmpty ? "Systran/faster-distil-whisper-large-v3" : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: "whisperaTranscriptionDirectModel") }
	}

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
		case .auto:
			return AutoTranscriber.shared
		case .whisperKit:
			return WhisperKitTranscriber.shared
		case .whisperViaBYOK:
			return RemoteBatchTranscriber.byok
		case .whisperaStreaming:
			return StreamingTranscriber.shared
		case .realtimeDirect:
			return StreamingTranscriber.direct
		}
	}
}
