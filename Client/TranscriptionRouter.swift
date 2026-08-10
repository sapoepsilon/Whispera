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

/// One-time split of the transcription-server URL into per-mode keys. The old
/// single key was shared between the backend proxy (whisperaStreaming, e.g.
/// http://127.0.0.1:3000) and a directly-addressed engine (realtimeDirect,
/// e.g. http://192.168.50.140:8000/v1) — switching engines silently reused
/// the other mode's URL and 404ed. The legacy value lands in whichever new
/// key matches the engine that was selected when it was typed, so current
/// setups keep working. Pure and defaults-injected so the whole table is
/// testable against an isolated suite — see TranscriptionServerURLMigrationTests.
enum TranscriptionServerURLMigration {
	static let legacyKey = "whisperaTranscriptionServerURL"
	static let migratedFlagKey = "whisperaTranscriptionServerURLKeysSplit"

	static func migrateIfNeeded(in defaults: UserDefaults) {
		guard !defaults.bool(forKey: migratedFlagKey) else { return }
		defaults.set(true, forKey: migratedFlagKey)

		let legacy = defaults.string(forKey: legacyKey) ?? ""
		guard !legacy.isEmpty else { return }

		let engine =
			TranscriptionEngine(
				rawValue: defaults.string(forKey: WhisperaSettings.transcriptionEngineKey) ?? "")
			?? .auto
		let destination =
			engine == .realtimeDirect
			? WhisperaSettings.transcriptionDirectURLKey
			: WhisperaSettings.transcriptionBackendURLKey
		// Never clobber a value the user already typed into a new key.
		guard (defaults.string(forKey: destination) ?? "").isEmpty else { return }
		defaults.set(legacy, forKey: destination)
		AppLogger.shared.general.info(
			"Split legacy transcription server URL into \(destination)")
	}
}

extension WhisperaSettings {
	static let transcriptionEngineKey = "whisperaTranscriptionEngine"
	static let transcriptionBackendURLKey = "whisperaTranscriptionBackendURL"
	static let transcriptionDirectURLKey = "whisperaTranscriptionDirectURL"
	static let transcriptionServerIdKey = "whisperaTranscriptionServerId"
	static let transcriptionDirectModelKey = "whisperaTranscriptionDirectModel"

	/// Unknown or absent raw values fall back to `auto` — a fresh install and a
	/// build that had an engine this one no longer ships land on the same
	/// default, which is honest because `auto` degrades to on-device itself
	/// whenever nothing is configured. Mirrors `llmMode`.
	static var transcriptionEngine: TranscriptionEngine {
		get {
			TranscriptionEngine(
				rawValue: UserDefaults.standard.string(forKey: transcriptionEngineKey) ?? "")
				?? .auto
		}
		set { UserDefaults.standard.set(newValue.rawValue, forKey: transcriptionEngineKey) }
	}

	/// Base URL of the Whispera transcription backend (the proxy `auto` and
	/// `whisperaStreaming` talk to). Separate from `serverURLString` because the
	/// streaming proxy can live somewhere other than the account backend; empty
	/// means "use the account backend".
	static var transcriptionBackendURLString: String {
		get {
			TranscriptionServerURLMigration.migrateIfNeeded(in: .standard)
			let stored = UserDefaults.standard.string(forKey: transcriptionBackendURLKey) ?? ""
			return stored.isEmpty ? serverURLString : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: transcriptionBackendURLKey) }
	}

	static var transcriptionBackendURL: URL? { url(from: transcriptionBackendURLString) }

	/// Base URL of a directly-addressed OpenAI-compatible engine (the
	/// `realtimeDirect` mode), ending in /v1. Its own key rather than sharing the
	/// backend's: the two are different machines with different URL shapes, and
	/// one shared field meant switching engines silently kept the wrong one.
	/// No account-server fallback — with no URL the direct engine is simply
	/// unconfigured, which surfaces as `invalidServerURL` instead of a 404
	/// against a server that is not an engine.
	static var transcriptionDirectURLString: String {
		get {
			TranscriptionServerURLMigration.migrateIfNeeded(in: .standard)
			return UserDefaults.standard.string(forKey: transcriptionDirectURLKey) ?? ""
		}
		set { UserDefaults.standard.set(newValue, forKey: transcriptionDirectURLKey) }
	}

	static var transcriptionDirectURL: URL? { url(from: transcriptionDirectURLString) }

	/// The URL for whichever engine is currently selected. Read-only and routed
	/// by engine: the streaming conformers' default `baseURLProvider` closures
	/// (which live in a file another change owns right now) all read this one
	/// property, and the routing is what guarantees each of them resolves the
	/// URL that belongs to its mode.
	static var transcriptionServerURLString: String {
		transcriptionEngine == .realtimeDirect
			? transcriptionDirectURLString
			: transcriptionBackendURLString
	}

	static var transcriptionServerURL: URL? { url(from: transcriptionServerURLString) }

	private static func url(from string: String) -> URL? {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : URL(string: trimmed)
	}

	/// Which engine on that backend to stream through. Empty means "let the
	/// backend's own `/transcription/servers` listing pick its default".
	/// The model to ask a directly-addressed engine for. Only consulted in
	/// `.realtimeDirect`: with no backend there is no `/transcription/servers`
	/// to name one, so the host has to.
	static var transcriptionDirectModel: String {
		get {
			let stored = UserDefaults.standard.string(forKey: transcriptionDirectModelKey) ?? ""
			return stored.isEmpty ? "Systran/faster-distil-whisper-large-v3" : stored
		}
		set { UserDefaults.standard.set(newValue, forKey: transcriptionDirectModelKey) }
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
