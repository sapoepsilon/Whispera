import AVFoundation
import Foundation
import Testing

@testable import Whispera

/// Most store tests exercise saved audio, which is opt-in, so they opt in unless told not to.
private func makeDefaults(_ name: String = #function, optInToAudio: Bool = true) -> UserDefaults {
	let suite = "TranscriptionHistoryTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	defaults.removePersistentDomain(forName: suite)
	if optInToAudio { defaults.set(true, forKey: HistorySettings.saveAudioKey) }
	return defaults
}

private func makeTempDirectory() -> URL {
	let url = FileManager.default.temporaryDirectory
		.appendingPathComponent("WhisperaHistoryTests-\(UUID().uuidString)", isDirectory: true)
	try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

private final class Clock {
	var now: Date
	init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
	func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func tone(seconds: Double, sampleRate: Int = 16000) -> [Float] {
	(0..<Int(seconds * Double(sampleRate))).map { index in
		0.5 * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
	}
}

// MARK: - Retention policy

struct HistoryRetentionTests {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private let day: TimeInterval = 86_400

	private func candidate(daysAgo: Double, starred: Bool = false) -> HistoryRetentionCandidate {
		HistoryRetentionCandidate(
			id: UUID(), createdAt: now.addingTimeInterval(-daysAgo * day), isStarred: starred)
	}

	@Test func neverDeletesNothing() {
		let candidates = (0..<20).map { candidate(daysAgo: Double($0) * 100) }
		#expect(HistoryRetention.idsToDelete(from: candidates, period: .never, limit: 1, now: now).isEmpty)
	}

	@Test func preserveLimitKeepsNewestUnstarred() {
		let newest = candidate(daysAgo: 0)
		let middle = candidate(daysAgo: 1)
		let oldest = candidate(daysAgo: 2)
		let doomed = HistoryRetention.idsToDelete(
			from: [oldest, newest, middle], period: .preserveLimit, limit: 2, now: now)
		#expect(doomed == [oldest.id])
	}

	@Test func preserveLimitIgnoresStarredEntries() {
		let starredOld = candidate(daysAgo: 30, starred: true)
		let starredNew = candidate(daysAgo: 0, starred: true)
		let a = candidate(daysAgo: 1)
		let b = candidate(daysAgo: 2)
		let doomed = HistoryRetention.idsToDelete(
			from: [starredOld, starredNew, a, b], period: .preserveLimit, limit: 1, now: now)
		#expect(doomed == [b.id], "Starred entries neither get deleted nor use up the limit")
	}

	@Test(arguments: [
		(HistoryRetentionPeriod.days3, 3.0),
		(.weeks2, 14.0),
		(.months3, 90.0),
	])
	func timeBasedPeriodsDeleteOlderUnstarred(period: HistoryRetentionPeriod, days: Double) {
		let fresh = candidate(daysAgo: days - 0.5)
		let stale = candidate(daysAgo: days + 0.5)
		let staleStarred = candidate(daysAgo: days + 10, starred: true)
		let doomed = HistoryRetention.idsToDelete(
			from: [fresh, stale, staleStarred], period: period, limit: 1, now: now)
		#expect(doomed == [stale.id])
	}

	@Test func negativeLimitDoesNotCrash() {
		let doomed = HistoryRetention.idsToDelete(
			from: [candidate(daysAgo: 0)], period: .preserveLimit, limit: -3, now: now)
		#expect(doomed.count == 1)
	}
}

// MARK: - Settings persistence

struct HistorySettingsTests {
	@Test func emptyDefaultsUseDocumentedDefaults() {
		let settings = HistorySettings(defaults: makeDefaults(optInToAudio: false))
		#expect(settings == HistorySettings())
		#expect(settings.isEnabled)
		#expect(!settings.savesAudio, "Saving raw audio must be opt-in for new and upgrading users")
		#expect(!settings.keepsAudio)
		#expect(settings.retention == .preserveLimit)
		#expect(settings.limit == 50)
	}

	@Test func roundTripsThroughUserDefaults() {
		let defaults = makeDefaults()
		let settings = HistorySettings(isEnabled: false, savesAudio: false, retention: .weeks2, limit: 7)
		settings.save(to: defaults)
		#expect(HistorySettings(defaults: defaults) == settings)
	}

	@Test func invalidValuesFallBackOrClamp() {
		let defaults = makeDefaults()
		defaults.set("forever-and-ever", forKey: HistorySettings.retentionKey)
		defaults.set(0, forKey: HistorySettings.limitKey)
		let settings = HistorySettings(defaults: defaults)
		#expect(settings.retention == HistorySettings.defaultRetention)
		#expect(settings.limit == HistorySettings.limitRange.lowerBound)
	}
}

// MARK: - WAV encoding

struct WAVFileWriterTests {
	@Test func headerDescribes16BitMonoPCM() {
		let data = WAVFileWriter.data(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
		#expect(data.count == 44 + 4 * 2)
		#expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
		#expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
		#expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
		let sampleRate = data[24..<28].enumerated().reduce(UInt32(0)) {
			$0 | UInt32($1.element) << (8 * UInt32($1.offset))
		}
		#expect(sampleRate == 16000)
	}

	@Test func readsBackThroughAVAudioFile() throws {
		let url = makeTempDirectory().appendingPathComponent("tone.wav")
		let samples = tone(seconds: 0.25)
		try WAVFileWriter.write(samples: samples, sampleRate: 16000, to: url)

		let file = try AVAudioFile(forReading: url)
		#expect(file.fileFormat.sampleRate == 16000)
		#expect(file.fileFormat.channelCount == 1)
		#expect(file.length == AVAudioFramePosition(samples.count))

		let buffer = try #require(
			AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
		try file.read(into: buffer)
		let decoded = try #require(buffer.floatChannelData?[0])
		for index in stride(from: 0, to: samples.count, by: 97) {
			#expect(abs(decoded[index] - samples[index]) < 0.001)
		}
	}

	@Test func clampsOutOfRangeAndNonFiniteSamples() {
		let data = WAVFileWriter.data(samples: [2, -2, .nan], sampleRate: 16000)
		let pcm = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
		#expect(pcm == [Int16.max, -Int16.max, 0])
	}
}

// MARK: - Store

@MainActor
struct TranscriptionHistoryStoreTests {
	@Test func recordsEntryWithSavedAudio() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "  hello world \n", audio: .samples(tone(seconds: 2), sampleRate: 16000),
				source: .dictation, modelName: "openai_whisper-small", language: "english"))

		#expect(entry.text == "hello world")
		#expect(abs(entry.durationSeconds - 2) < 0.001)
		#expect(entry.modelName == "openai_whisper-small")
		#expect(entry.language == "english")
		#expect(store.entries.map(\.id) == [entry.id])
		await store.flushPendingAudioWrites()
		let url = try #require(store.audioURL(for: entry))
		#expect(try AVAudioFile(forReading: url).length == 32000)
	}

	@Test func skipsEmptyTextUnlessItFailed() async {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		#expect(store.record(text: "   ", audio: nil, source: .dictation, modelName: nil, language: nil) == nil)

		let failed = store.record(
			text: "", audio: .samples(tone(seconds: 1), sampleRate: 16000), source: .dictation,
			modelName: nil, language: nil, errorMessage: "Model not ready")
		#expect(failed?.didFail == true)
		await store.flushPendingAudioWrites()
		#expect(failed.flatMap(store.audioURL(for:)) != nil, "Failed dictations keep audio so they can be retried")
	}

	@Test func disabledHistoryRecordsNothing() {
		let defaults = makeDefaults()
		defaults.set(false, forKey: HistorySettings.enabledKey)
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: defaults)
		#expect(store.record(text: "secret", audio: nil, source: .dictation, modelName: nil, language: nil) == nil)
		#expect(store.entries.isEmpty)
	}

	@Test func audioOptOutKeepsTextOnly() throws {
		let defaults = makeDefaults()
		defaults.set(false, forKey: HistorySettings.saveAudioKey)
		let directory = makeTempDirectory()
		let store = TranscriptionHistoryStore(directory: directory, defaults: defaults)
		let entry = try #require(
			store.record(
				text: "text only", audio: .samples(tone(seconds: 1), sampleRate: 16000),
				source: .dictation, modelName: nil, language: nil))
		#expect(entry.audioFileName == nil)
		#expect(entry.durationSeconds > 0.99)
		#expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
	}

	@Test func fileAudioIsMovedIntoHistory() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let source = makeTempDirectory().appendingPathComponent("recording.wav")
		try WAVFileWriter.write(samples: tone(seconds: 1.5), sampleRate: 16000, to: source)

		let entry = try #require(
			store.record(
				text: "from file", audio: .file(source), source: .dictation, modelName: nil, language: nil))
		#expect(!FileManager.default.fileExists(atPath: source.path))
		#expect(store.audioURL(for: entry) != nil)
		#expect(abs(entry.durationSeconds - 1.5) < 0.01)
	}

	@Test func persistsAcrossStoreInstances() async throws {
		let directory = makeTempDirectory()
		let defaults = makeDefaults()
		do {
			let store = TranscriptionHistoryStore(directory: directory, defaults: defaults)
			let entry = try #require(
				store.record(
					text: "persisted", audio: .samples(tone(seconds: 1), sampleRate: 16000),
					source: .liveDictation, modelName: "tiny", language: "english"))
			store.toggleStar(entry)
			await store.flushPendingAudioWrites()
		}

		let reopened = TranscriptionHistoryStore(directory: directory, defaults: defaults)
		let entry = try #require(reopened.entries.first)
		#expect(reopened.entries.count == 1)
		#expect(entry.text == "persisted")
		#expect(entry.isStarred)
		#expect(entry.source == .liveDictation)
		#expect(reopened.audioURL(for: entry) != nil)
	}

	@Test func newestFirstAndLimitEnforcedOnRecord() async throws {
		let defaults = makeDefaults()
		defaults.set(2, forKey: HistorySettings.limitKey)
		let clock = Clock()
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, now: { clock.now })

		let first = try #require(
			store.record(
				text: "one", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		await store.flushPendingAudioWrites()
		let firstAudio = try #require(store.audioURL(for: first))
		clock.advance(1)
		store.record(text: "two", audio: nil, source: .dictation, modelName: nil, language: nil)
		clock.advance(1)
		store.record(text: "three", audio: nil, source: .dictation, modelName: nil, language: nil)

		#expect(store.entries.map(\.text) == ["three", "two"])
		#expect(
			!FileManager.default.fileExists(atPath: firstAudio.path), "Pruned entries take their audio with them")
	}

	@Test func starredEntriesSurviveRetentionAndClear() throws {
		let defaults = makeDefaults()
		defaults.set(1, forKey: HistorySettings.limitKey)
		let clock = Clock()
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, now: { clock.now })

		let keeper = try #require(
			store.record(text: "keep me", audio: nil, source: .dictation, modelName: nil, language: nil))
		store.toggleStar(keeper)
		clock.advance(1)
		store.record(text: "a", audio: nil, source: .dictation, modelName: nil, language: nil)
		clock.advance(1)
		store.record(text: "b", audio: nil, source: .dictation, modelName: nil, language: nil)
		#expect(store.entries.map(\.text) == ["b", "keep me"])

		store.deleteAllUnstarred()
		#expect(store.entries.map(\.text) == ["keep me"])
	}

	@Test func timeRetentionPrunesOnLaunch() throws {
		let directory = makeTempDirectory()
		let defaults = makeDefaults()
		defaults.set(HistoryRetentionPeriod.days3.rawValue, forKey: HistorySettings.retentionKey)
		let clock = Clock()
		do {
			let store = TranscriptionHistoryStore(directory: directory, defaults: defaults, now: { clock.now })
			store.record(text: "old", audio: nil, source: .dictation, modelName: nil, language: nil)
		}
		clock.advance(4 * 86_400)
		let reopened = TranscriptionHistoryStore(directory: directory, defaults: defaults, now: { clock.now })
		#expect(reopened.entries.isEmpty)
	}

	@Test func deleteRemovesEntryAndAudio() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "bye", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		await store.flushPendingAudioWrites()
		let url = try #require(store.audioURL(for: entry))
		store.delete(entry)
		#expect(store.entries.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: url.path))
	}

	@Test func applyingTranscriptionClearsFailure() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "", audio: nil, source: .dictation, modelName: nil, language: nil,
				errorMessage: "boom"))
		store.applyTranscription(" recovered ", modelName: "base", language: "english", to: entry)
		#expect(entry.text == "recovered")
		#expect(!entry.didFail)
		#expect(entry.modelName == "base")
		#expect(entry.retranscribedAt != nil)
	}

	@Test func retranscribeWithoutAudioThrows() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(text: "no audio", audio: nil, source: .dictation, modelName: nil, language: nil))
		await #expect(throws: TranscriptionHistoryError.self) {
			try await store.retranscribe(entry)
		}
	}

	@Test func deleteAllEntriesRemovesStarredEntriesAndEveryRecording() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let starred = try #require(
			store.record(
				text: "starred", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		store.toggleStar(starred)
		store.record(
			text: "plain", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
			modelName: nil, language: nil)
		await store.flushPendingAudioWrites()
		#expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).count == 2)

		store.deleteAllEntries()
		#expect(store.entries.isEmpty)
		store.reload()
		#expect(store.entries.isEmpty)
		#expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
	}

	@Test func deleteAllRecordingsKeepsTheText() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "keep my words", audio: .samples(tone(seconds: 0.5), sampleRate: 16000),
				source: .dictation, modelName: nil, language: nil))
		await store.flushPendingAudioWrites()
		#expect(store.hasSavedRecordings)

		store.deleteAllRecordings()
		#expect(!store.hasSavedRecordings)
		#expect(entry.audioFileName == nil)
		#expect(store.entries.map(\.text) == ["keep my words"])
		#expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
	}

	@Test func recordingDeletedWhileItsFileIsBeingWrittenLeavesNoOrphan() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "short lived", audio: .samples(tone(seconds: 3), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		store.delete(entry)
		await store.flushPendingAudioWrites()
		#expect(try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).isEmpty)
	}

	@Test func recordingsFolderIsExcludedFromBackups() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let values = try store.audioDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)
	}

	@Test func unstarringAnOldEntryDoesNotDeleteItImmediately() throws {
		let defaults = makeDefaults()
		defaults.set(1, forKey: HistorySettings.limitKey)
		let clock = Clock()
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, now: { clock.now })
		let old = try #require(
			store.record(text: "old", audio: nil, source: .dictation, modelName: nil, language: nil))
		store.toggleStar(old)
		clock.advance(1)
		store.record(text: "new", audio: nil, source: .dictation, modelName: nil, language: nil)
		#expect(store.entries.count == 2)

		store.toggleStar(old)
		#expect(store.entries.map(\.text) == ["new", "old"])
	}

	@Test func retranscribingAnEntryDeletedMidFlightDoesNotTouchIt() async throws {
		let directory = makeTempDirectory()
		let defaults = makeDefaults()
		let store = TranscriptionHistoryStore(directory: directory, defaults: defaults)
		let entry = try #require(
			store.record(
				text: "original", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		await store.flushPendingAudioWrites()
		let id = entry.id

		try await store.retranscribe(entry) { _ in
			store.delete(entry)
			return ("resurrected", "tiny")
		}

		#expect(store.entries.isEmpty)
		#expect(!store.retranscribingIDs.contains(id))
		let reopened = TranscriptionHistoryStore(directory: directory, defaults: defaults)
		#expect(reopened.entries.isEmpty, "A deleted entry must not come back with the new text")
	}

	@Test func failedRetranscriptionOfADeletedEntryStillThrowsWithoutWriting() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "original", audio: .samples(tone(seconds: 0.5), sampleRate: 16000), source: .dictation,
				modelName: nil, language: nil))
		await store.flushPendingAudioWrites()

		await #expect(throws: TranscriptionHistoryError.self) {
			try await store.retranscribe(entry) { _ in
				store.delete(entry)
				throw TranscriptionHistoryError.storeUnavailable
			}
		}
		#expect(store.entries.isEmpty)
	}

	@Test func filterMatchesTextAndStar() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let apple = try #require(
			store.record(text: "Buy apples", audio: nil, source: .dictation, modelName: nil, language: nil))
		store.record(text: "Call Bob", audio: nil, source: .dictation, modelName: nil, language: nil)
		store.toggleStar(apple)

		#expect(
			TranscriptionHistoryStore.filter(store.entries, query: "APPLE", starredOnly: false).map(\.text) == [
				"Buy apples"
			])
		#expect(
			TranscriptionHistoryStore.filter(store.entries, query: "", starredOnly: true).map(\.text) == [
				"Buy apples"
			])
		#expect(TranscriptionHistoryStore.filter(store.entries, query: " ", starredOnly: false).count == 2)
	}
}

// MARK: - Live session text

struct LiveSessionTextTests {
	@Test func joinsConfirmedAndPending() {
		#expect(
			WhisperKitTranscriber.liveSessionText(confirmed: "Hello there.", pending: " How are you? ")
				== "Hello there. How are you?")
	}

	@Test func dropsPlaceholderAndEmptyParts() {
		#expect(
			WhisperKitTranscriber.liveSessionText(
				confirmed: "", pending: WhisperKitTranscriber.liveWaitingPlaceholder) == "")
		#expect(WhisperKitTranscriber.liveSessionText(confirmed: "Only", pending: "") == "Only")
	}
}

// MARK: - Re-transcription with real WhisperKit

// Uses whichever model the app already downloaded; the shared transcriber loads it on demand.
private let hasDownloadedModel: Bool = {
	let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("Whispera/models/argmaxinc/whisperkit-coreml")
	let contents = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
	return contents.contains { $0.hasPrefix("openai_whisper") || $0.hasPrefix("distil") }
}()

@MainActor
struct HistoryRetranscriptionTests {
	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func retranscribesSavedRecordingWithWhisperKit() async throws {
		let directory = makeTempDirectory()
		let spoken = directory.appendingPathComponent("spoken.wav")
		let say = Process()
		say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
		say.arguments = [
			"-o", spoken.path, "--data-format=LEI16@16000", "The quick brown fox jumps over the lazy dog.",
		]
		try say.run()
		say.waitUntilExit()
		try #require(say.terminationStatus == 0)

		let store = TranscriptionHistoryStore(directory: directory, defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "", audio: .file(spoken), source: .dictation, modelName: nil, language: nil,
				errorMessage: "Model was not ready"))

		let transcriber = WhisperKitTranscriber.shared
		try await transcriber.waitForReadyForTranscription(timeoutSeconds: 240)
		try await store.retranscribe(entry, transcriber: transcriber, enableTranslation: false)

		#expect(!entry.didFail)
		#expect(entry.text.localizedCaseInsensitiveContains("fox"), "Got: \(entry.text)")
		#expect(entry.retranscribedAt != nil)
		#expect(!store.retranscribingIDs.contains(entry.id))
	}

	/// The speech model is real; only the LLM, an external service, is stood in for.
	@Test(.enabled(if: hasDownloadedModel), .timeLimit(.minutes(10)))
	func retryRerunsPostProcessingForAPostProcessedEntry() async throws {
		let directory = makeTempDirectory()
		let spoken = directory.appendingPathComponent("spoken.wav")
		let say = Process()
		say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
		say.arguments = ["-o", spoken.path, "--data-format=LEI16@16000", "The quick brown fox jumps over the lazy dog."]
		try say.run()
		say.waitUntilExit()
		try #require(say.terminationStatus == 0)

		let store = TranscriptionHistoryStore(directory: directory, defaults: makeDefaults())
		let prompt = PostProcessingPrompt(id: "shout", name: "Shout", template: "${output}")
		let entry = try #require(
			store.record(
				text: "stale", audio: .file(spoken), source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(
					PostProcessingRun(prompt: prompt, outcome: .processed("STALE")))))

		let transcriber = WhisperKitTranscriber.shared
		try await transcriber.waitForReadyForTranscription(timeoutSeconds: 240)
		try await store.retranscribe(entry, transcriber: transcriber, enableTranslation: false) { input in
			PostProcessingRun(prompt: prompt, outcome: .processed(input.uppercased()))
		}

		#expect(entry.rawText?.localizedCaseInsensitiveContains("fox") == true, "Got: \(entry.rawText ?? "nil")")
		#expect(entry.text.contains("FOX"), "Got: \(entry.text)")
		#expect(entry.postProcessPromptName == "Shout")
		#expect(entry.postProcessRequested)
	}
}

// MARK: - Post-processed history

private let cleanupPrompt = PostProcessingPrompt(id: "cleanup", name: "Clean up", template: "Fix: ${output}")

private func run(_ outcome: PostProcessingOutcome) -> PostProcessingRun {
	PostProcessingRun(prompt: cleanupPrompt, outcome: outcome)
}

struct HistoryPostProcessingMappingTests {
	@Test func processedRunKeepsTextAndPrompt() {
		let record = HistoryPostProcessing(run(.processed("Hello.")))
		#expect(record.processedText == "Hello.")
		#expect(record.promptName == "Clean up")
		#expect(record.promptTemplate == "Fix: ${output}")
		#expect(record.errorMessage == nil)
	}

	@Test func failedRunKeepsErrorWithoutText() {
		let record = HistoryPostProcessing(run(.failed(original: "hello", error: "HTTP 500")))
		#expect(record.processedText == nil)
		#expect(record.errorMessage == "HTTP 500")
	}

	@Test func skippedRunHasNeitherTextNorError() {
		let record = HistoryPostProcessing(run(.skipped(original: "")))
		#expect(record.processedText == nil)
		#expect(record.errorMessage == nil)
	}
}

@MainActor
struct PostProcessedHistoryStoreTests {
	@Test func recordsRawAndPostProcessedText() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: " um hello world ", audio: nil, source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(run(.processed(" Hello, world. ")))))

		#expect(entry.text == "Hello, world.")
		#expect(entry.rawText == "um hello world")
		#expect(entry.transcriptText == "um hello world")
		#expect(entry.postProcessedText == "Hello, world.")
		#expect(entry.postProcessPromptName == "Clean up")
		#expect(entry.postProcessPrompt == "Fix: ${output}")
		#expect(entry.postProcessRequested)
		#expect(entry.wasPostProcessed)
	}

	@Test func failedPostProcessingKeepsRawTextAndError() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "hello", audio: nil, source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(run(.failed(original: "hello", error: "timeout")))))

		#expect(entry.text == "hello")
		#expect(entry.rawText == "hello")
		#expect(entry.postProcessedText == nil)
		#expect(entry.postProcessError == "timeout")
		#expect(entry.postProcessRequested)
		#expect(!entry.didFail, "A failed LLM pass is not a failed transcription")
	}

	@Test func plainDictationHasNoPostProcessingFields() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(text: "plain", audio: nil, source: .dictation, modelName: nil, language: nil))
		#expect(entry.rawText == nil)
		#expect(entry.transcriptText == "plain")
		#expect(!entry.postProcessRequested)
	}

	@Test func postProcessingFieldsPersist() throws {
		let directory = makeTempDirectory()
		let defaults = makeDefaults()
		do {
			let store = TranscriptionHistoryStore(directory: directory, defaults: defaults)
			store.record(
				text: "raw words", audio: nil, source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(run(.processed("Clean words."))))
		}
		let reopened = TranscriptionHistoryStore(directory: directory, defaults: defaults)
		let entry = try #require(reopened.entries.first)
		#expect(entry.text == "Clean words.")
		#expect(entry.rawText == "raw words")
		#expect(entry.postProcessPromptName == "Clean up")
		#expect(entry.postProcessRequested)
	}

	@Test func reprocessRunsOnTheOriginalTranscript() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "first draft", audio: nil, source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(run(.processed("First draft.")))))

		let seen = SeenInputs()
		try await store.reprocess(entry) { input in
			await seen.append(input)
			return run(.processed(input.uppercased()))
		}

		#expect(await seen.values == ["first draft"], "Must post-process the raw text, not the last output")
		#expect(entry.text == "FIRST DRAFT")
		#expect(entry.rawText == "first draft")
		#expect(entry.retranscribedAt != nil)
		#expect(!store.retranscribingIDs.contains(entry.id))
	}

	@Test func reprocessAddsPostProcessingToAPlainEntry() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(text: "plain words", audio: nil, source: .dictation, modelName: nil, language: nil))
		try await store.reprocess(entry) { _ in run(.processed("Plain words.")) }
		#expect(entry.text == "Plain words.")
		#expect(entry.rawText == "plain words")
		#expect(entry.postProcessRequested)
	}

	@Test func reprocessOfAFailedEntryWithoutTextThrows() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "", audio: nil, source: .dictation, modelName: nil, language: nil, errorMessage: "boom"))
		await #expect(throws: TranscriptionHistoryError.self) {
			try await store.reprocess(entry) { _ in run(.processed("x")) }
		}
	}

	@Test func plainRetranscriptionClearsPostProcessing() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let entry = try #require(
			store.record(
				text: "raw", audio: nil, source: .dictation, modelName: nil, language: nil,
				postProcessing: HistoryPostProcessing(run(.processed("Processed.")))))
		store.applyTranscription("again", modelName: nil, language: nil, to: entry)
		#expect(entry.text == "again")
		#expect(entry.rawText == nil)
		#expect(entry.postProcessPromptName == nil)
		#expect(!entry.postProcessRequested)
	}

	@Test func searchMatchesTheOriginalTranscript() throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		store.record(
			text: "gonna buy apples", audio: nil, source: .dictation, modelName: nil, language: nil,
			postProcessing: HistoryPostProcessing(run(.processed("I will buy fruit."))))
		#expect(TranscriptionHistoryStore.filter(store.entries, query: "gonna", starredOnly: false).count == 1)
		#expect(TranscriptionHistoryStore.filter(store.entries, query: "fruit", starredOnly: false).count == 1)
	}
}

private actor SeenInputs {
	var values: [String] = []
	func append(_ value: String) { values.append(value) }
}

// MARK: - Debounced retention

@MainActor
struct DebouncedActionTests {
	@Test func burstOfSchedulesRunsOnlyTheLastActionOnce() async throws {
		let debouncer = DebouncedAction(delay: .milliseconds(80))
		var runs: [Int] = []
		for value in [50, 45, 40, 35, 30] {
			debouncer.schedule { runs.append(value) }
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(runs.isEmpty, "Intermediate Stepper values must not apply retention")
		try await Task.sleep(for: .milliseconds(300))
		#expect(runs == [30])
	}

	@Test func flushRunsPendingActionImmediatelyAndOnlyOnce() async throws {
		let debouncer = DebouncedAction(delay: .seconds(10))
		var runs = 0
		debouncer.schedule { runs += 1 }
		#expect(debouncer.isPending)
		debouncer.flush()
		debouncer.flush()
		#expect(runs == 1)
		#expect(!debouncer.isPending)
	}

	@Test func cancelDropsPendingAction() async throws {
		let debouncer = DebouncedAction(delay: .milliseconds(20))
		var runs = 0
		debouncer.schedule { runs += 1 }
		debouncer.cancel()
		try await Task.sleep(for: .milliseconds(100))
		#expect(runs == 0)
	}
}

// MARK: - Privacy hygiene

@MainActor
struct TranscriptionHistoryPrivacyTests {
	private func bytesOnDisk(_ store: TranscriptionHistoryStore) -> Data {
		var data = Data()
		for suffix in ["", "-wal", "-shm"] {
			if let chunk = try? Data(contentsOf: URL(fileURLWithPath: store.storeURL.path + suffix)) {
				data.append(chunk)
			}
		}
		return data
	}

	@Test func historyFolderIsExcludedFromBackups() throws {
		let directory = makeTempDirectory()
		let store = TranscriptionHistoryStore(directory: directory, defaults: makeDefaults())
		_ = store.record(text: "backup check", audio: nil, source: .dictation, modelName: nil, language: nil)

		let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)
		let recordings = try store.audioDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(recordings.isExcludedFromBackup == true)
	}

	@Test func deletedTextIsScrubbedFromTheDatabaseFiles() async {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let marker = "QUOKKA-\(UUID().uuidString)"
		for index in 0..<5 {
			_ = store.record(
				text: "\(marker) number \(index)", audio: nil, source: .dictation, modelName: nil, language: nil)
		}
		#expect(bytesOnDisk(store).range(of: Data(marker.utf8)) != nil, "The marker should be on disk first")

		store.deleteAllEntries()
		await store.flushScrub()

		#expect(store.entries.isEmpty)
		#expect(bytesOnDisk(store).range(of: Data(marker.utf8)) == nil, "Deleted text is still recoverable")
	}

	@Test func storeKeepsWorkingAfterAScrub() async throws {
		let store = TranscriptionHistoryStore(directory: makeTempDirectory(), defaults: makeDefaults())
		let doomed = try #require(
			store.record(text: "delete me", audio: nil, source: .dictation, modelName: nil, language: nil))
		store.delete(doomed)
		await store.flushScrub()

		let kept = store.record(text: "still works", audio: nil, source: .dictation, modelName: nil, language: nil)
		#expect(kept != nil)
		store.reload()
		#expect(store.entries.map(\.text) == ["still works"])
	}

	@Test func turningHistoryOffAnywhereAsksToPurge() {
		let defaults = makeDefaults()
		var prompts = 0
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, presentOptOutPrompt: { prompts += 1 })
		_ = store.record(text: "one", audio: nil, source: .dictation, modelName: nil, language: nil)
		_ = store.record(text: "two", audio: nil, source: .dictation, modelName: nil, language: nil)

		// Same as `defaults write ... historyEnabled -bool NO` or a toggle outside the history view
		defaults.set(false, forKey: HistorySettings.enabledKey)

		#expect(store.pendingOptOutPurge == 2)
		#expect(prompts == 1, "No history view is open, so the window must be brought up to ask")

		store.deleteAllEntries()
		#expect(store.pendingOptOutPurge == nil)
		#expect(store.entries.isEmpty)
	}

	@Test func openHistoryViewShowsThePromptItself() {
		let defaults = makeDefaults()
		var prompts = 0
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, presentOptOutPrompt: { prompts += 1 })
		_ = store.record(text: "one", audio: nil, source: .dictation, modelName: nil, language: nil)
		store.viewDidAppear()

		defaults.set(false, forKey: HistorySettings.enabledKey)
		#expect(store.pendingOptOutPurge == 1)
		#expect(prompts == 0)

		store.keepEntriesAfterOptOut()
		#expect(store.pendingOptOutPurge == nil)
		#expect(store.entries.count == 1)
	}

	@Test func noPromptWithoutEntriesOrWhenTurningHistoryOn() {
		let defaults = makeDefaults()
		var prompts = 0
		let store = TranscriptionHistoryStore(
			directory: makeTempDirectory(), defaults: defaults, presentOptOutPrompt: { prompts += 1 })
		defaults.set(false, forKey: HistorySettings.enabledKey)
		defaults.set(true, forKey: HistorySettings.enabledKey)
		#expect(store.pendingOptOutPurge == nil)
		#expect(prompts == 0)
	}
}
