import Foundation
import Testing

@testable import Whispera

struct ModelUnloadTimeoutSettingTests {
	private func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "ModelUnloadTimeoutSettingTests.\(name).\(UUID().uuidString)"
		return UserDefaults(suiteName: suite)!
	}

	@Test func defaultsToNever() {
		let settings = RecordingControlSettings(defaults: makeDefaults())
		#expect(settings.modelUnloadTimeout == .never)
		#expect(settings.modelUnloadTimeout.interval == nil)
	}

	@Test func readsStoredTimeout() {
		let defaults = makeDefaults()
		defaults.set(ModelUnloadTimeout.minutes5.rawValue, forKey: RecordingControlSettings.Key.modelUnloadTimeout)
		#expect(RecordingControlSettings(defaults: defaults).modelUnloadTimeout == .minutes5)
	}

	@Test func unknownStoredValueFallsBackToNever() {
		let defaults = makeDefaults()
		defaults.set("bogus", forKey: RecordingControlSettings.Key.modelUnloadTimeout)
		#expect(RecordingControlSettings(defaults: defaults).modelUnloadTimeout == .never)
	}

	@Test func intervalsMatchLabels() {
		#expect(ModelUnloadTimeout.immediately.interval == 0)
		#expect(ModelUnloadTimeout.seconds15.interval == 15)
		#expect(ModelUnloadTimeout.minutes1.interval == 60)
		#expect(ModelUnloadTimeout.minutes2.interval == 120)
		#expect(ModelUnloadTimeout.minutes10.interval == 600)
		#expect(ModelUnloadTimeout.minutes5.interval == 300)
		#expect(ModelUnloadTimeout.minutes15.interval == 900)
		#expect(ModelUnloadTimeout.hour1.interval == 3600)
	}
}

@MainActor
struct DeferredActionTests {
	@Test func firesAfterDelay() async throws {
		let action = DeferredAction()
		var fired = 0
		action.schedule(after: 0.05) { fired += 1 }
		#expect(action.isScheduled)
		try await Task.sleep(nanoseconds: 300_000_000)
		#expect(fired == 1)
		#expect(!action.isScheduled)
	}

	@Test func cancelPreventsFiring() async throws {
		let action = DeferredAction()
		var fired = false
		action.schedule(after: 0.05) { fired = true }
		action.cancel()
		try await Task.sleep(nanoseconds: 300_000_000)
		#expect(!fired)
	}

	@Test func reschedulingReplacesPendingAction() async throws {
		let action = DeferredAction()
		var calls: [String] = []
		action.schedule(after: 0.05) { calls.append("first") }
		action.schedule(after: 0.05) { calls.append("second") }
		try await Task.sleep(nanoseconds: 300_000_000)
		#expect(calls == ["second"])
	}
}

/// Exercises a real WhisperKit unload and on-demand reload. Needs a downloaded model.
@MainActor
@Suite(.serialized, .sharedTranscriber)
struct ModelIdleUnloadIntegrationTests {
	nonisolated static var hasDownloadedModel: Bool {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera/models/argmaxinc/whisperkit-coreml")
		let contents = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
		return contents.contains { $0.hasPrefix("openai_whisper") || $0.hasPrefix("distil") }
	}

	private func waitUntilIdleAndLoaded(_ transcriber: WhisperKitTranscriber) async throws {
		let deadline = Date().addingTimeInterval(150)
		while Date() < deadline {
			if transcriber.isInitialized && transcriber.isCurrentModelLoaded() && transcriber.canUnloadModel {
				return
			}
			try await Task.sleep(nanoseconds: 250_000_000)
		}
		Issue.record(
			"Model never became idle and loaded: initialized=\(transcriber.isInitialized) initializing=\(transcriber.isInitializing) status=\(transcriber.initializationStatus) state=\(transcriber.modelState) loading=\(transcriber.isModelLoading) hasKit=\(transcriber.whisperKit != nil) blockers=\(transcriber.idleUnloadBlockers)"
		)
		throw CancellationError()
	}

	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func unloadReleasesModelAndNextTranscriptionReloadsIt() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitUntilIdleAndLoaded(transcriber)
		#expect(transcriber.isCurrentModelLoaded())

		await transcriber.unloadModel()
		#expect(transcriber.whisperKit == nil)
		#expect(transcriber.isIdleUnloaded)
		#expect(!transcriber.isModelLoaded)
		#expect(transcriber.hasAnyModel())

		let silence = [Float](repeating: 0, count: 16000)
		_ = try await transcriber.transcribeAudioArray(silence, enableTranslation: false)

		#expect(transcriber.whisperKit != nil)
		#expect(transcriber.isCurrentModelLoaded())
		#expect(!transcriber.isIdleUnloaded)
	}

	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func unloadIsRefusedWhileModelIsInUse() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitUntilIdleAndLoaded(transcriber)

		transcriber.beginModelUse()
		#expect(!transcriber.canUnloadModel)
		await transcriber.unloadModel()
		#expect(transcriber.whisperKit != nil)
		transcriber.endModelUse()
		#expect(transcriber.canUnloadModel)
	}

	private func withUnloadTimeout<T>(_ timeout: ModelUnloadTimeout, _ body: () async throws -> T) async rethrows -> T {
		let defaults = UserDefaults.standard
		let key = RecordingControlSettings.Key.modelUnloadTimeout
		let saved = defaults.object(forKey: key)
		defaults.set(timeout.rawValue, forKey: key)
		defer { defaults.set(saved, forKey: key) }
		return try await body()
	}

	private func waitFor(
		_ what: String, seconds: TimeInterval = 150, _ condition: () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return }
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		Issue.record("Timed out waiting for \(what)")
		throw CancellationError()
	}

	/// Handy #2106: a recording whose audio came to nothing ends without a transcription, and
	/// with "Immediately" the model must still be released instead of staying warm.
	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func recordingWithNoAudioStillUnloadsImmediately() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitUntilIdleAndLoaded(transcriber)
		// What AudioManager does for a recording: hold on start, release when it is dropped
		transcriber.beginModelUse()
		try await withUnloadTimeout(.immediately) {
			try await Task.sleep(nanoseconds: 300_000_000)
			#expect(transcriber.whisperKit != nil, "The model must stay loaded while a recording holds it")
			transcriber.endModelUse()
			try await waitFor("the idle unload", seconds: 30) { transcriber.whisperKit == nil }
			#expect(transcriber.isIdleUnloaded)
		}
		try await transcriber.waitForReadyForTranscription(timeoutSeconds: 120)
	}

	/// A recording that starts after an idle unload reloads the model ahead of time. When that
	/// recording turns out to have no audio, the reload it triggered must not keep the model warm.
	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func emptyRecordingAfterIdleUnloadDoesNotKeepThePreloadedModel() async throws {
		let transcriber = WhisperKitTranscriber.shared
		try await waitUntilIdleAndLoaded(transcriber)
		try await withUnloadTimeout(.immediately) {
			// Nothing holds the model, so choosing Immediately releases it on its own
			try await waitFor("the idle unload", seconds: 30) { transcriber.whisperKit == nil }
			try #require(transcriber.isIdleUnloaded)

			transcriber.beginModelUse()
			transcriber.preloadModelIfIdleUnloaded()
			try await waitFor("the preload to start") { transcriber.isModelLoading || transcriber.whisperKit != nil }
			transcriber.endModelUse()

			try await waitFor("the preloaded model to be released") {
				!transcriber.isModelLoading && transcriber.whisperKit == nil && transcriber.isIdleUnloaded
			}
			#expect(transcriber.isIdleUnloaded)
		}
		try await transcriber.waitForReadyForTranscription(timeoutSeconds: 120)
	}
}

