// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaOpenAI

/// One configured OpenAI-compatible server, per capability.
///
/// This replaces `LLMMode {local, byok}`. That enum was a UI split over a
/// single executor: both arms built the same `LocalLLMExecutor`, differing only
/// in which base URL and which Keychain account they read. Because BYOK was a
/// closed two-provider enum with hardcoded URLs, "bring your own key to any
/// OpenAI-compatible cloud" was unreachable except by typing a cloud URL into
/// the slot labelled *Local* — so groq, openrouter and a LAN box were all
/// configurable only by lying to the UI.
///
/// What is left once the mode goes away is the thing that was always underneath:
/// a base URL, an optional key, and a model. Whether that URL is localhost or
/// `api.openai.com` is not a mode, it is an address. See WHI-91, WHI-92.
struct ServerEntry: Equatable, Sendable {
	/// What a server is *for*. Two entries, not one list of many: the app has
	/// exactly two remote capabilities, and asking a user to tag each server
	/// with what it does would be ceremony over a choice they have already made
	/// by typing the address into one field rather than the other.
	enum Capability: String, CaseIterable, Sendable {
		case llm
		case speech

		var displayName: String {
			switch self {
			case .llm: return "LLM server"
			case .speech: return "Speech server"
			}
		}

		/// Keychain account. Keyed by capability rather than by a `ProviderId`,
		/// which is the change that makes an arbitrary base URL storable at all.
		var keychainId: String {
			switch self {
			case .llm: return "llm-server"
			case .speech: return "speech-server"
			}
		}

		/// The UserDefaults keys stay the ones the old Local/direct slots already
		/// used. Reusing them rather than inventing a pair is what makes the
		/// common upgrade — someone who had configured a local LLM server, or a
		/// direct speech engine — a no-op instead of a migration.
		var urlKey: String {
			switch self {
			case .llm: return "whisperaLocalServerURL"
			case .speech: return "whisperaTranscriptionDirectURL"
			}
		}

		var modelKey: String {
			switch self {
			case .llm: return "whisperaLocalModel"
			case .speech: return "whisperaTranscriptionDirectModel"
			}
		}

		var placeholderURL: String {
			switch self {
			case .llm: return "http://localhost:11434/v1"
			case .speech: return "http://192.168.0.10:8000/v1"
			}
		}

		var placeholderModel: String {
			switch self {
			case .llm: return "llama3.2"
			case .speech: return "Systran/faster-distil-whisper-large-v3"
			}
		}

		/// Prefilled base URLs, offered as a convenience. Deliberately *not* a
		/// provider enum: picking one only writes into the URL field, and the
		/// user can edit or ignore it. Adding a provider here gives it no
		/// privileges that typing its URL by hand would not.
		var presets: [ServerPreset] {
			switch self {
			case .llm:
				return [
					ServerPreset(name: "Local (ollama)", urlString: "http://localhost:11434/v1", model: ""),
					ServerPreset(name: "OpenAI", urlString: "https://api.openai.com/v1", model: "gpt-4o-mini"),
					// Anthropic through its OpenAI-compatible shim, not native
					// /v1/messages. Owner decision, 2026-08-18 (WHI-91): a native
					// path would reintroduce the provider enum this ticket deletes,
					// for one provider, when that provider already speaks
					// chat/completions.
					ServerPreset(
						name: "Anthropic", urlString: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5"),
					ServerPreset(
						name: "Groq", urlString: "https://api.groq.com/openai/v1",
						model: "llama-3.3-70b-versatile"),
				]
			case .speech:
				return [
					ServerPreset(name: "Local (speaches)", urlString: "http://localhost:8000/v1", model: ""),
					ServerPreset(name: "OpenAI", urlString: "https://api.openai.com/v1", model: "whisper-1"),
					ServerPreset(
						name: "Groq", urlString: "https://api.groq.com/openai/v1", model: "whisper-large-v3"),
				]
			}
		}
	}

	var capability: Capability
	var urlString: String
	var model: String

	/// The base URL as typed, normalised. `nil` when the field cannot yet be a
	/// server — which is the state a half-typed address is in, and the reason
	/// nothing probes it. See `ServerURLNormalizer`.
	var url: URL? { ServerURLNormalizer.normalize(urlString) }

	var hasKey: Bool { OpenAIKeyStore.shared.hasKey(serverId: capability.keychainId) }

	/// A key provider rather than the key: the material is read at request time
	/// and dropped, never held on a settings struct.
	var keyProvider: @Sendable () -> String? {
		OpenAIKeyStore.shared.keyProvider(serverId: capability.keychainId)
	}
}

struct ServerPreset: Equatable, Sendable, Identifiable {
	let name: String
	let urlString: String
	let model: String

	var id: String { name }
}

/// What a typed URL is missing, phrased as a hint rather than a failure.
///
/// WHI-86: an address the user is halfway through typing is not a broken
/// server, and telling them it is unreachable is both alarming and untrue. A
/// hint says what is still missing; the orange unreachable warning is reserved
/// for a well-formed URL that actually failed.
enum ServerURLHint: Equatable, Sendable {
	case empty
	case needsHost
	case needsPort
	case needsVersionPath

	var message: String {
		switch self {
		case .empty: return "Enter the server's OpenAI-compatible base URL."
		case .needsHost: return "Add a host, e.g. 192.168.0.10 or api.openai.com."
		case .needsPort: return "Add the port, e.g. :8000."
		case .needsVersionPath: return "The base should end in /v1."
		}
	}
}

/// Turns what the user typed into something worth sending a request to, or
/// says why it is not one yet.
///
/// The old `url(from:)` only trimmed whitespace, so `192.168.50.140` parsed as
/// a `URL` with no scheme and no host and was probed anyway — producing the
/// "could not reach 192.168.50.140" warning in WHI-86's screenshot against an
/// address that was never a server in the first place.
enum ServerURLNormalizer {
	static let defaultEnginePort = 8000

	/// `nil` when the input cannot address a server yet. Anything non-nil is
	/// safe to probe.
	static func normalize(_ raw: String) -> URL? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		// A bare host or host:port has no scheme, so URLComponents puts the whole
		// thing in `path` and leaves `host` nil. Default to http rather than
		// https: the addresses typed without a scheme are LAN engines, and
		// guessing https at one would fail the handshake rather than the parse.
		let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
		guard var components = URLComponents(string: withScheme),
			let host = components.host, !host.isEmpty
		else { return nil }

		// A trailing dot or a lone label is still being typed.
		guard !host.hasSuffix("."), host != "http", host != "https" else { return nil }

		var path = components.path
		while path.hasSuffix("/") { path.removeLast() }
		if !path.hasSuffix("/v1") { path += "/v1" }
		components.path = path
		components.query = nil
		components.fragment = nil

		return components.url
	}

	/// What is still missing, for the inline hint. Returns `nil` once the value
	/// is good enough to send a request to.
	static func hint(for raw: String) -> ServerURLHint? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return .empty }
		guard let url = normalize(trimmed) else { return .needsHost }

		// Only a bare IP literal gets the port hint. A hostname without a port is
		// ordinary (api.openai.com), an IP without one almost never is — the
		// engines this addresses all listen on a non-default port.
		if url.port == nil, let host = url.host, isIPLiteral(host) {
			return .needsPort
		}
		if !trimmed.contains("/v1") { return .needsVersionPath }
		return nil
	}

	/// The suggestion shown next to `.needsPort`, so the hint can be acted on
	/// with one click rather than retyped.
	static func withDefaultPort(_ raw: String) -> String {
		guard let url = normalize(raw), url.port == nil, var components = URLComponents(string: url.absoluteString)
		else { return raw }
		components.port = defaultEnginePort
		return components.url?.absoluteString ?? raw
	}

	private static func isIPLiteral(_ host: String) -> Bool {
		let parts = host.split(separator: ".")
		guard parts.count == 4 else { return false }
		return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
	}
}

extension WhisperaSettings {
	static func serverEntry(_ capability: ServerEntry.Capability, in defaults: UserDefaults = .standard)
		-> ServerEntry
	{
		ServerEntryMigration.migrateIfNeeded(in: defaults)
		return ServerEntry(
			capability: capability,
			urlString: defaults.string(forKey: capability.urlKey) ?? "",
			model: defaults.string(forKey: capability.modelKey) ?? "")
	}

	/// The LLM server recipe steps run against.
	static var llmServer: ServerEntry { serverEntry(.llm) }

	/// The speech server batch uploads and the direct streaming engine share.
	/// One entry, because they are one address: WHI-92's whole finding was that
	/// batch had a second, pinned URL that no setting could reach.
	static var speechServer: ServerEntry { serverEntry(.speech) }
}

/// One-time collapse of `LLMMode` and the BYOK provider keys into the two
/// server entries.
///
/// The upgrade must cost an existing install nothing, so each old shape lands
/// on the entry that behaves the same way it did:
///
/// * `mode == .local` — the URL, model and optional bearer key were already an
///   arbitrary OpenAI-compatible server. They stay exactly where they are; the
///   Keychain account is renamed from `local-server` to `llm-server`.
/// * `mode == .byok` — the two provider key rows had no URL field at all, so
///   the URL is synthesised from whichever provider had a key saved
///   (Anthropic's OpenAI-compatible shim when only that one did, otherwise
///   OpenAI) and `whisperaByokModel` becomes the entry's model. The key moves
///   to the `llm-server` account.
/// * `whisperaByokTranscriptionModel` — the batch transcription model, which
///   previously only ever meant `whisper-1` against the pinned `api.openai.com`.
///   It becomes the speech entry's model, and the OpenAI key moves to
///   `speech-server`, only when the speech entry has nothing configured yet.
///
/// Nothing already typed into a destination key is overwritten, so re-running
/// the migration is inert and a user who configured the new UI before an old
/// key was noticed does not lose it.
enum ServerEntryMigration {
	static let migratedFlagKey = "whisperaServerEntriesMigrated"
	static let legacyModeKey = "whisperaLLMMode"
	static let legacyByokModelKey = "whisperaByokModel"
	static let legacyByokTranscriptionModelKey = "whisperaByokTranscriptionModel"

	static let openAIBaseURL = "https://api.openai.com/v1"
	static let anthropicBaseURL = "https://api.anthropic.com/v1"

	/// A key store the migration can move accounts within. `OpenAIKeyStore` and
	/// the app's old store share one Keychain service, so both old and new
	/// accounts are reachable through the package type.
	static func migrateIfNeeded(
		in defaults: UserDefaults,
		keyStore: OpenAIKeyStore = .shared
	) {
		guard !defaults.bool(forKey: migratedFlagKey) else { return }
		defaults.set(true, forKey: migratedFlagKey)

		let mode = defaults.string(forKey: legacyModeKey) ?? ""
		let savedAccounts = Set((try? keyStore.serverIds()) ?? [])

		// Speech first: it *copies* the OpenAI key, and the LLM pass *moves* it.
		// The other order leaves the speech entry pointing at a server whose key
		// has already been renamed out from under it.
		migrateSpeech(defaults: defaults, keyStore: keyStore, savedAccounts: savedAccounts)
		migrateLLM(mode: mode, defaults: defaults, keyStore: keyStore, savedAccounts: savedAccounts)

		defaults.removeObject(forKey: legacyModeKey)
		AppLogger.shared.general.info("Collapsed LLM mode settings into per-capability server entries")
	}

	private static func migrateLLM(
		mode: String, defaults: UserDefaults, keyStore: OpenAIKeyStore, savedAccounts: Set<String>
	) {
		let capability = ServerEntry.Capability.llm

		if mode == "byok" {
			// Only Anthropic configured means the user was talking to Anthropic;
			// anything else (both, or OpenAI alone) means OpenAI.
			let onlyAnthropic =
				savedAccounts.contains("anthropic") && !savedAccounts.contains("openai")
			let source = onlyAnthropic ? "anthropic" : "openai"
			setIfEmpty(defaults, capability.urlKey, onlyAnthropic ? anthropicBaseURL : openAIBaseURL)
			setIfEmpty(defaults, capability.modelKey, defaults.string(forKey: legacyByokModelKey) ?? "")
			move(key: source, to: capability.keychainId, in: keyStore)
		} else {
			// Local, or a raw value no build ever wrote. Either way the local slot
			// is what the router used, so it is what the entry inherits.
			move(key: "local-server", to: capability.keychainId, in: keyStore)
		}
	}

	private static func migrateSpeech(
		defaults: UserDefaults, keyStore: OpenAIKeyStore, savedAccounts: Set<String>
	) {
		let capability = ServerEntry.Capability.speech
		let alreadyConfigured = !(defaults.string(forKey: capability.urlKey) ?? "").isEmpty
		guard !alreadyConfigured else {
			// A direct engine was already configured, and its model used to fall
			// back to this string in a computed property rather than being stored.
			// Write it down so removing that default changes nothing for them.
			setIfEmpty(defaults, capability.modelKey, "Systran/faster-distil-whisper-large-v3")
			return
		}

		// No direct engine was ever configured, so the only speech server this
		// install could have been using is the one batch was pinned to.
		guard savedAccounts.contains("openai") else { return }
		defaults.set(openAIBaseURL, forKey: capability.urlKey)
		setIfEmpty(
			defaults, capability.modelKey,
			defaults.string(forKey: legacyByokTranscriptionModelKey) ?? "whisper-1")
		copy(key: "openai", to: capability.keychainId, in: keyStore)
	}

	private static func setIfEmpty(_ defaults: UserDefaults, _ key: String, _ value: String) {
		guard !value.isEmpty, (defaults.string(forKey: key) ?? "").isEmpty else { return }
		defaults.set(value, forKey: key)
	}

	private static func copy(key source: String, to destination: String, in keyStore: OpenAIKeyStore) {
		guard let value = (try? keyStore.load(serverId: source)) ?? nil, !value.isEmpty,
			((try? keyStore.load(serverId: destination)) ?? nil) == nil
		else { return }
		try? keyStore.save(serverId: destination, key: value)
	}

	private static func move(key source: String, to destination: String, in keyStore: OpenAIKeyStore) {
		copy(key: source, to: destination, in: keyStore)
		try? keyStore.delete(serverId: source)
	}
}
