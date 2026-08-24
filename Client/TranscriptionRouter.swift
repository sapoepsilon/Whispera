// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Where speech-to-text runs. Identity only — what each engine can do lives on
/// the conformer as `TranscriptionCapabilities`, so adding a case never reopens
/// a switch anywhere but here. See WHI-42, WHI-58, WHI-74.
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

	/// What a fresh install runs, and what an unrecognised stored value degrades
	/// to. See `WhisperaSettings.transcriptionEngine` for why it is on-device
	/// rather than `auto` (WHI-74).
	static let fresh: TranscriptionEngine = .whisperKit

	/// The stored raw value, resolved. One place, so the fallback cannot drift
	/// between the settings accessor and the two views that read the key
	/// directly — and so the default is testable without writing to
	/// `UserDefaults.standard`, which the host app's `@AppStorage` bindings
	/// observe.
	static func stored(_ raw: String?) -> TranscriptionEngine {
		TranscriptionEngine(rawValue: raw ?? "") ?? .fresh
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

	/// Unknown or absent raw values fall back to `whisperKit` — a fresh install
	/// and a build that had an engine this one no longer ships land on the same
	/// default.
	///
	/// On-device rather than `auto`, and that is the WHI-74 call. `auto` ranks on
	/// advertised delta granularity, so against the live backend it selects
	/// nemo-stream — the one engine whose delta contract is known to be broken
	/// (WHI-67), which makes the very first dictation a new user ever runs the
	/// worst version of the product. WhisperKit needs no server, no account and
	/// no network, and it is already what `auto` degrades to whenever nothing is
	/// configured, which is the common fresh-install case anyway. Owner's call,
	/// 2026-08-18: "default = on-device WhisperKit, auto prefers speaches over
	/// nemo-stream". Revisit once the delta contract is verified end to end.
	static var transcriptionEngine: TranscriptionEngine {
		get { .stored(UserDefaults.standard.string(forKey: transcriptionEngineKey)) }
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

	/// Normalised, unlike the backend URL below it: this is the speech server
	/// entry's address, and a base typed as `192.168.50.140` has to become
	/// `http://192.168.50.140/v1` before anything is sent to it. The backend
	/// proxy is deliberately left alone — it is not an OpenAI-compatible base
	/// and appending /v1 to it would 404. See WHI-86, WHI-92.
	static var transcriptionDirectURL: URL? {
		ServerURLNormalizer.normalize(transcriptionDirectURLString)
	}

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
	///
	/// The direct engine's model moved onto the speech `ServerEntry`
	/// (`WhisperaSettings.speechServer.model`, same defaults key) so that batch
	/// upload and live streaming name one model for one server instead of two —
	/// see WHI-91, WHI-92.
	static var transcriptionServerId: String {
		get { UserDefaults.standard.string(forKey: transcriptionServerIdKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: transcriptionServerIdKey) }
	}

	/// Writes the engine, and only the engine.
	///
	/// The settings picker used to also flip `enableStreaming` on whenever the
	/// chosen engine streamed from a server, so choosing "OpenAI-Realtime server
	/// (direct)" in order to *configure* it silently switched the app into live
	/// dictation mode (WHI-86). Selecting an engine describes a consequence; it
	/// does not cause one. Defaults-injected so the guarantee is testable
	/// without writing to `UserDefaults.standard`, which the host app's
	/// `@AppStorage` bindings observe.
	static func selectEngine(_ engine: TranscriptionEngine, in defaults: UserDefaults = .standard) {
		defaults.set(engine.rawValue, forKey: transcriptionEngineKey)
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
