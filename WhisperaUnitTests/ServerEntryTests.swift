// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaOpenAI

@testable import Whispera

/// Turning what a user typed into something worth sending a request to.
///
/// The bug this pins (WHI-86): `192.168.50.140` used to parse as a `URL`,
/// because `url(from:)` only trimmed whitespace, and was then probed — so an
/// orange "Could not reach 192.168.50.140 to list its models" sat under an
/// address that had no scheme, no port and no `/v1` and was never a server.
struct ServerURLNormalizerTests {
	@Test func aBareHostAndPortBecomesAnHTTPBaseEndingInV1() {
		#expect(
			ServerURLNormalizer.normalize("192.168.50.140:8000")?.absoluteString
				== "http://192.168.50.140:8000/v1")
	}

	/// http, not https: an address typed without a scheme is a LAN engine, and
	/// guessing https at one fails the handshake rather than the parse.
	@Test func theDefaultSchemeIsHTTP() {
		#expect(ServerURLNormalizer.normalize("localhost:8000")?.scheme == "http")
		#expect(ServerURLNormalizer.normalize("https://api.openai.com/v1")?.scheme == "https")
	}

	@Test func anExistingV1BaseIsLeftAlone() {
		#expect(
			ServerURLNormalizer.normalize("http://192.168.50.140:8000/v1")?.absoluteString
				== "http://192.168.50.140:8000/v1")
	}

	@Test func aTrailingSlashDoesNotProduceADoubleSlash() {
		#expect(
			ServerURLNormalizer.normalize("http://localhost:8000/")?.absoluteString
				== "http://localhost:8000/v1")
	}

	@Test func nothingUsableParsesToNil() {
		for raw in ["", "   ", "http://", "https://", "192.168.50."] {
			#expect(ServerURLNormalizer.normalize(raw) == nil, "\(raw) should not be a server URL")
		}
	}

	// MARK: - Hints

	@Test func anEmptyFieldAsksForAURLRatherThanReportingAFailure() {
		#expect(ServerURLNormalizer.hint(for: "") == .empty)
	}

	@Test func anIPWithNoPortHintsAtTheDefaultEnginePort() {
		#expect(ServerURLNormalizer.hint(for: "192.168.50.140") == .needsPort)
		#expect(
			ServerURLNormalizer.withDefaultPort("192.168.50.140")
				== "http://192.168.50.140:8000/v1")
	}

	/// A hostname without a port is ordinary; only a bare IP literal earns the
	/// port hint, or every cloud URL would carry a spurious one.
	@Test func aHostnameWithoutAPortIsNotHinted() {
		#expect(ServerURLNormalizer.hint(for: "https://api.openai.com/v1") == nil)
	}

	@Test func aBaseMissingV1IsHintedRatherThanRejected() {
		#expect(ServerURLNormalizer.hint(for: "http://localhost:8000") == .needsVersionPath)
	}

	@Test func aCompleteAddressHasNoHint() {
		#expect(ServerURLNormalizer.hint(for: "http://192.168.50.140:8000/v1") == nil)
	}
}

/// WHI-86 acceptance 1: "typing any prefix of a valid URL produces no network
/// request until the field settles". The debounce is half of that guarantee;
/// this is the other half, and the one that holds even if a timer fires early.
struct ServerProbePolicyTests {
	@Test func noPrefixOfAnAddressBeingTypedIsEverProbed() {
		let target = "192.168.50.140:8000/v1"
		let prefixes = ServerProbePolicy.typingPrefixes(of: target).dropLast()
		for prefix in prefixes {
			#expect(!ServerProbePolicy.shouldProbe(prefix), "typing “\(prefix)” must not probe")
		}
		#expect(ServerProbePolicy.shouldProbe(target))
	}

	@Test func theDebounceIsAtLeastTheSixHundredMillisecondsTheTicketAsksFor() {
		#expect(ServerProbePolicy.debounceMilliseconds >= 600)
	}
}

/// WHI-86 acceptance 2: "selecting any engine in Settings leaves
/// `enableStreaming` exactly as the user set it."
///
/// The picker used to flip Live Transcription Mode on for any engine that
/// streams from a server, so opening Settings to *configure* the direct engine
/// switched the app into live dictation.
struct EngineSelectionSideEffectTests {
	private func suite() -> UserDefaults {
		UserDefaults(suiteName: "engine-selection-\(UUID().uuidString)")!
	}

	@Test func choosingAServerEngineDoesNotTouchLiveTranscriptionMode() {
		let defaults = suite()
		defaults.set(false, forKey: "enableStreaming")

		for engine in TranscriptionEngine.allCases {
			WhisperaSettings.selectEngine(engine, in: defaults)
			#expect(
				defaults.bool(forKey: "enableStreaming") == false,
				"selecting \(engine.rawValue) must not enable streaming")
		}
	}

	@Test func theEngineIsStillWritten() {
		let defaults = suite()
		WhisperaSettings.selectEngine(.realtimeDirect, in: defaults)
		#expect(
			defaults.string(forKey: WhisperaSettings.transcriptionEngineKey)
				== TranscriptionEngine.realtimeDirect.rawValue)
	}

	/// Every engine that streams is covered above, but naming them here makes
	/// the regression obvious if a case is added without thinking about it.
	@Test func theServerEnginesAreTheOnesThisEverAppliedTo() {
		#expect(TranscriptionEngine.whisperaStreaming.streamsFromAServer)
		#expect(TranscriptionEngine.realtimeDirect.streamsFromAServer)
	}
}

/// WHI-91: an existing install must keep working after the upgrade with no
/// reconfiguration. Each old shape has to land on an entry that behaves the
/// same way it did.
struct ServerEntryMigrationTests {
	private func suite() -> UserDefaults {
		UserDefaults(suiteName: "server-entry-\(UUID().uuidString)")!
	}

	private func keyStore() -> OpenAIKeyStore {
		OpenAIKeyStore(service: "com.whispera.byok.test.\(UUID().uuidString)")
	}

	private func cleanUp(_ store: OpenAIKeyStore) {
		for id in (try? store.serverIds()) ?? [] { try? store.delete(serverId: id) }
	}

	@Test func localModeKeepsItsURLModelAndKey() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("local", forKey: ServerEntryMigration.legacyModeKey)
		defaults.set("http://192.168.1.5:1234/v1", forKey: ServerEntry.Capability.llm.urlKey)
		defaults.set("qwen2.5", forKey: ServerEntry.Capability.llm.modelKey)
		try store.save(serverId: "local-server", key: "proxy-token")

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(defaults.string(forKey: ServerEntry.Capability.llm.urlKey) == "http://192.168.1.5:1234/v1")
		#expect(defaults.string(forKey: ServerEntry.Capability.llm.modelKey) == "qwen2.5")
		#expect(try store.load(serverId: "llm-server") == "proxy-token")
		#expect(try store.load(serverId: "local-server") == nil)
	}

	/// BYOK had no URL field at all, so the address has to be synthesised from
	/// whichever provider the user actually had a key for.
	@Test func byokWithAnOpenAIKeyBecomesTheOpenAIBaseURL() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("byok", forKey: ServerEntryMigration.legacyModeKey)
		defaults.set("gpt-4o", forKey: ServerEntryMigration.legacyByokModelKey)
		try store.save(serverId: "openai", key: "sk-live")

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(
			defaults.string(forKey: ServerEntry.Capability.llm.urlKey)
				== ServerEntryMigration.openAIBaseURL)
		#expect(defaults.string(forKey: ServerEntry.Capability.llm.modelKey) == "gpt-4o")
		#expect(try store.load(serverId: "llm-server") == "sk-live")
	}

	/// Anthropic through its OpenAI-compatible shim — the recorded decision on
	/// WHI-91. Someone who had only an Anthropic key was talking to Anthropic,
	/// so that is the base URL they land on.
	@Test func byokWithOnlyAnAnthropicKeyBecomesTheAnthropicBaseURL() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("byok", forKey: ServerEntryMigration.legacyModeKey)
		try store.save(serverId: "anthropic", key: "sk-ant-live")

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(
			defaults.string(forKey: ServerEntry.Capability.llm.urlKey)
				== ServerEntryMigration.anthropicBaseURL)
		#expect(try store.load(serverId: "llm-server") == "sk-ant-live")
	}

	/// Batch transcription was pinned to `api.openai.com`, so an install with an
	/// OpenAI key and no direct engine was, in effect, configured for that
	/// server. It becomes one it can now see and change (WHI-92).
	@Test func aByokBatchInstallGainsAnEditableSpeechServer() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("byok", forKey: ServerEntryMigration.legacyModeKey)
		defaults.set("whisper-1", forKey: ServerEntryMigration.legacyByokTranscriptionModelKey)
		try store.save(serverId: "openai", key: "sk-live")

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(
			defaults.string(forKey: ServerEntry.Capability.speech.urlKey)
				== ServerEntryMigration.openAIBaseURL)
		#expect(defaults.string(forKey: ServerEntry.Capability.speech.modelKey) == "whisper-1")
		#expect(try store.load(serverId: "speech-server") == "sk-live")
	}

	/// A direct engine already configured is left exactly where it is — except
	/// that the model default it used to get from a computed property is written
	/// down, so removing that property changes nothing for them.
	@Test func aConfiguredDirectEngineIsUntouchedApartFromPinningItsModel() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("http://192.168.50.140:8000/v1", forKey: ServerEntry.Capability.speech.urlKey)

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(
			defaults.string(forKey: ServerEntry.Capability.speech.urlKey)
				== "http://192.168.50.140:8000/v1")
		#expect(
			defaults.string(forKey: ServerEntry.Capability.speech.modelKey)
				== "Systran/faster-distil-whisper-large-v3")
	}

	@Test func aFreshInstallGetsNothingItDidNotAskFor() {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect((defaults.string(forKey: ServerEntry.Capability.llm.urlKey) ?? "").isEmpty)
		#expect((defaults.string(forKey: ServerEntry.Capability.speech.urlKey) ?? "").isEmpty)
	}

	@Test func migratingTwiceIsInert() throws {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("byok", forKey: ServerEntryMigration.legacyModeKey)
		try store.save(serverId: "openai", key: "sk-live")

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)
		defaults.set("http://elsewhere:1/v1", forKey: ServerEntry.Capability.llm.urlKey)
		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(defaults.string(forKey: ServerEntry.Capability.llm.urlKey) == "http://elsewhere:1/v1")
	}

	/// The mode key is what the deleted enum was stored under. Leaving it behind
	/// would let a future build resurrect a setting that no longer means
	/// anything.
	@Test func theModeKeyIsRemoved() {
		let defaults = suite()
		let store = keyStore()
		defer { cleanUp(store) }
		defaults.set("byok", forKey: ServerEntryMigration.legacyModeKey)

		ServerEntryMigration.migrateIfNeeded(in: defaults, keyStore: store)

		#expect(defaults.string(forKey: ServerEntryMigration.legacyModeKey) == nil)
	}
}
