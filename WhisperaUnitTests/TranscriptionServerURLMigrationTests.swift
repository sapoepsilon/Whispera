// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

@testable import Whispera

/// The one-time split of the shared transcription-server URL into per-mode
/// keys. Each test gets its own defaults suite: these run in parallel and the
/// host app's own @AppStorage bindings watch the standard suite.
struct TranscriptionServerURLMigrationTests {
	private static func isolatedDefaults() -> UserDefaults {
		UserDefaults(suiteName: "TranscriptionServerURLMigrationTests-\(UUID().uuidString)")!
	}

	@Test func legacyURLForTheDirectEngineLandsInTheDirectKey() {
		let defaults = Self.isolatedDefaults()
		defaults.set("http://192.168.50.140:8000/v1", forKey: TranscriptionServerURLMigration.legacyKey)
		defaults.set(
			TranscriptionEngine.realtimeDirect.rawValue,
			forKey: WhisperaSettings.transcriptionEngineKey)

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(
			defaults.string(forKey: WhisperaSettings.transcriptionDirectURLKey)
				== "http://192.168.50.140:8000/v1")
		#expect(defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey) == nil)
	}

	@Test func legacyURLForABackendEngineLandsInTheBackendKey() {
		let defaults = Self.isolatedDefaults()
		defaults.set("http://127.0.0.1:3000", forKey: TranscriptionServerURLMigration.legacyKey)
		defaults.set(
			TranscriptionEngine.whisperaStreaming.rawValue,
			forKey: WhisperaSettings.transcriptionEngineKey)

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(
			defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey)
				== "http://127.0.0.1:3000")
		#expect(defaults.string(forKey: WhisperaSettings.transcriptionDirectURLKey) == nil)
	}

	/// No stored engine reads as `auto`, which streams through the backend, so
	/// the legacy URL belongs to the backend key.
	@Test func absentEngineTreatsTheLegacyURLAsTheBackends() {
		let defaults = Self.isolatedDefaults()
		defaults.set("http://127.0.0.1:3000", forKey: TranscriptionServerURLMigration.legacyKey)

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(
			defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey)
				== "http://127.0.0.1:3000")
	}

	/// Runs once: a user who later clears the new key must not have the legacy
	/// value resurrected behind their back.
	@Test func migrationDoesNotRunTwice() {
		let defaults = Self.isolatedDefaults()
		defaults.set("http://127.0.0.1:3000", forKey: TranscriptionServerURLMigration.legacyKey)

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)
		defaults.removeObject(forKey: WhisperaSettings.transcriptionBackendURLKey)
		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey) == nil)
	}

	@Test func migrationNeverOverwritesAValueAlreadyInTheNewKey() {
		let defaults = Self.isolatedDefaults()
		defaults.set("http://old.example:3000", forKey: TranscriptionServerURLMigration.legacyKey)
		defaults.set(
			"http://new.example:3000", forKey: WhisperaSettings.transcriptionBackendURLKey)

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(
			defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey)
				== "http://new.example:3000")
	}

	@Test func emptyLegacyValueMigratesNothingButStillMarksDone() {
		let defaults = Self.isolatedDefaults()

		TranscriptionServerURLMigration.migrateIfNeeded(in: defaults)

		#expect(defaults.bool(forKey: TranscriptionServerURLMigration.migratedFlagKey))
		#expect(defaults.string(forKey: WhisperaSettings.transcriptionBackendURLKey) == nil)
		#expect(defaults.string(forKey: WhisperaSettings.transcriptionDirectURLKey) == nil)
	}

	/// The Settings server list explains granularity in plain words; the raw
	/// protocol terms must never leak into the UI.
	@Test func granularityWordingStaysInPlainWords() {
		#expect(StreamingGranularity.nativeDelta.plainWords == "word-by-word")
		#expect(StreamingGranularity.synthesizedDelta.plainWords == "near-live")
		#expect(StreamingGranularity.utterance.plainWords == "at the end")
	}
}
