import AVFoundation
import Foundation
import Testing

@testable import Whispera

private final class CancelledClock {
	var now: Date
	init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
	func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct CancelledRecordingStoreTests {
	nonisolated private static func makeDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "CancelledRecordingStoreTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	nonisolated private static func makeDirectory() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("WhisperaCancelledRecordings-\(UUID().uuidString)", isDirectory: true)
	}

	nonisolated private static func samples(seconds: Double) -> [Float] {
		(0..<Int(seconds * 16000)).map { 0.3 * sin(2 * .pi * 440 * Float($0) / 16000) }
	}

	private func makeStore(
		directory: URL = makeDirectory(), defaults: UserDefaults = makeDefaults(),
		clock: CancelledClock = CancelledClock(), maxCount: Int = CancelledRecordingStore.defaultMaxCount
	) -> CancelledRecordingStore {
		CancelledRecordingStore(directory: directory, defaults: defaults, now: { clock.now }, maxCount: maxCount)
	}

	@Test func savesAReadable16kHzFileWithItsDuration() async throws {
		let store = makeStore()
		let recording = try #require(await store.save(samples: Self.samples(seconds: 2)))

		#expect(store.recordings == [recording])
		#expect(abs(recording.durationSeconds - 2) < 0.001)
		let url = try #require(store.url(for: recording))
		let file = try AVAudioFile(forReading: url)
		#expect(file.fileFormat.sampleRate == 16000)
		#expect(file.length == 32000)
	}

	@Test func skipsClipsShorterThanHalfASecond() async {
		let store = makeStore()
		let kept = await store.save(samples: Self.samples(seconds: 0.4))

		#expect(kept == nil)
		#expect(store.recordings.isEmpty)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
		#expect(files.isEmpty)
	}

	@Test func keepsHalfASecondExactly() async {
		let store = makeStore()
		#expect(await store.save(samples: Self.samples(seconds: 0.5)) != nil)
	}

	@Test func newestComesFirst() async throws {
		let clock = CancelledClock()
		let store = makeStore(clock: clock)
		let first = try #require(await store.save(samples: Self.samples(seconds: 1)))
		clock.advance(60)
		let second = try #require(await store.save(samples: Self.samples(seconds: 1)))

		#expect(store.recordings.map(\.id) == [second.id, first.id])
		#expect(store.latest == second)
	}

	@Test func prunesPastTheCountLimitAndRemovesTheirFiles() async throws {
		let clock = CancelledClock()
		let store = makeStore(clock: clock, maxCount: 2)
		let oldest = try #require(await store.save(samples: Self.samples(seconds: 1)))
		let oldestURL = try #require(store.url(for: oldest))
		for _ in 0..<2 {
			clock.advance(10)
			await store.save(samples: Self.samples(seconds: 1))
		}

		#expect(store.recordings.count == 2)
		#expect(!store.recordings.contains(oldest))
		#expect(!FileManager.default.fileExists(atPath: oldestURL.path))
	}

	@Test func prunesRecordingsOlderThanADay() async throws {
		let clock = CancelledClock()
		let store = makeStore(clock: clock)
		let old = try #require(await store.save(samples: Self.samples(seconds: 1)))
		let oldURL = try #require(store.url(for: old))
		clock.advance(CancelledRecordingStore.defaultMaxAge - 1)
		store.prune()
		#expect(store.recordings == [old])

		clock.advance(2)
		store.prune()
		#expect(store.recordings.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: oldURL.path))
	}

	@Test func deleteRemovesTheEntryAndItsFile() async throws {
		let store = makeStore()
		let keep = try #require(await store.save(samples: Self.samples(seconds: 1)))
		let doomed = try #require(await store.save(samples: Self.samples(seconds: 1)))
		let doomedURL = try #require(store.url(for: doomed))

		store.delete(doomed)

		#expect(store.recordings == [keep])
		#expect(!FileManager.default.fileExists(atPath: doomedURL.path))
		#expect(store.url(for: doomed) == nil)
	}

	@Test func deleteAllEmptiesTheFolder() async {
		let store = makeStore()
		await store.save(samples: Self.samples(seconds: 1))
		await store.save(samples: Self.samples(seconds: 1))

		store.deleteAll()

		#expect(store.recordings.isEmpty)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
		#expect(files.isEmpty)
	}

	@Test func survivesARelaunch() async throws {
		let directory = Self.makeDirectory()
		let defaults = Self.makeDefaults()
		let clock = CancelledClock()
		let saved = try #require(
			await makeStore(directory: directory, defaults: defaults, clock: clock)
				.save(samples: Self.samples(seconds: 1)))

		let reopened = makeStore(directory: directory, defaults: defaults, clock: clock)
		#expect(reopened.recordings == [saved])
	}

	@Test func relaunchDropsEntriesWhoseFileIsGoneAndStrayFiles() async throws {
		let directory = Self.makeDirectory()
		let defaults = Self.makeDefaults()
		let clock = CancelledClock()
		let store = makeStore(directory: directory, defaults: defaults, clock: clock)
		let lost = try #require(await store.save(samples: Self.samples(seconds: 1)))
		try FileManager.default.removeItem(at: try #require(store.url(for: lost)))
		let stray = directory.appendingPathComponent("\(UUID().uuidString).wav")
		try Data([0]).write(to: stray)

		let reopened = makeStore(directory: directory, defaults: defaults, clock: clock)
		#expect(reopened.recordings.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: stray.path))
	}

	@Test func joinsFileSegmentsAndRemovesTheParts() async throws {
		let scratch = Self.makeDirectory()
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		var segments: [FileRecordingSegments.Segment] = []
		for index in 0..<2 {
			let url = scratch.appendingPathComponent("part\(index).wav")
			try WAVFileWriter.write(samples: Self.samples(seconds: 1), sampleRate: 16000, to: url)
			segments.append(.init(url: url, channel: InputChannelSelection.mixAllChannels))
		}
		let store = makeStore()

		let recording = try #require(await store.save(segments: segments))

		#expect(abs(recording.durationSeconds - 2) < 0.01)
		for segment in segments {
			#expect(!FileManager.default.fileExists(atPath: segment.url.path))
		}
	}

	@Test func transcribeHandsOverTheFileAndCanBeCancelled() async throws {
		let store = makeStore()
		let recording = try #require(await store.save(samples: Self.samples(seconds: 1)))
		let expectedURL = try #require(store.url(for: recording))

		let text = try await store.transcribe(recording) { url in
			#expect(url == expectedURL)
			return "hello"
		}
		#expect(text == "hello")
		#expect(store.transcribingID == nil)

		let running = Task {
			try await store.transcribe(recording) { _ in
				try await Task.sleep(for: .seconds(30))
				return "too late"
			}
		}
		while store.transcribingID == nil { await Task.yield() }
		store.cancelTranscription()
		await #expect(throws: CancellationError.self) { try await running.value }
		#expect(store.transcribingID == nil)
	}

	@Test func transcribeThrowsWhenTheAudioIsGone() async throws {
		let store = makeStore()
		let recording = try #require(await store.save(samples: Self.samples(seconds: 1)))
		try FileManager.default.removeItem(at: try #require(store.url(for: recording)))

		await #expect(throws: CancelledRecordingError.self) {
			_ = try await store.transcribe(recording) { _ in "unused" }
		}
	}

	// MARK: - Privacy

	nonisolated private static func permissions(of url: URL) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return try #require(attributes[.posixPermissions] as? Int) & 0o777
	}

	@Test func createsTheFolderOwnerOnly() throws {
		let store = makeStore()
		#expect(try Self.permissions(of: store.directory) == 0o700)
	}

	@Test func tightensAnExistingFolderAndItsFiles() throws {
		let directory = Self.makeDirectory()
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
		let defaults = Self.makeDefaults()
		let saved = CancelledRecording(id: UUID(), createdAt: CancelledClock().now, durationSeconds: 1, fileName: "old.wav")
		let file = directory.appendingPathComponent(saved.fileName)
		try WAVFileWriter.write(samples: Self.samples(seconds: 1), sampleRate: 16000, to: file)
		try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
		defaults.set(try JSONEncoder().encode([saved]), forKey: CancelledRecordingStore.indexKey)

		let store = makeStore(directory: directory, defaults: defaults)

		#expect(store.recordings == [saved])
		#expect(try Self.permissions(of: directory) == 0o700)
		#expect(try Self.permissions(of: file) == 0o600)
	}

	@Test func writesRecordingsOwnerOnly() async throws {
		let store = makeStore()
		let recording = try #require(await store.save(samples: Self.samples(seconds: 1)))
		#expect(try Self.permissions(of: try #require(store.url(for: recording))) == 0o600)
	}

	@Test func writesJoinedSegmentsOwnerOnly() async throws {
		let scratch = Self.makeDirectory()
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		let part = scratch.appendingPathComponent("part.wav")
		try WAVFileWriter.write(samples: Self.samples(seconds: 1), sampleRate: 16000, to: part)
		let store = makeStore()

		let recording = try #require(
			await store.save(segments: [.init(url: part, channel: InputChannelSelection.mixAllChannels)]))

		#expect(try Self.permissions(of: try #require(store.url(for: recording))) == 0o600)
	}

	@Test func keepsRecordingsByDefault() {
		#expect(makeStore().keepsRecordings)
	}

	@Test func savingIsANoOpWhenKeepingIsOff() async {
		let defaults = Self.makeDefaults()
		defaults.set(false, forKey: CancelledRecordingStore.keepRecordingsKey)
		let store = makeStore(defaults: defaults)

		let kept = await store.save(samples: Self.samples(seconds: 2))

		#expect(kept == nil)
		#expect(store.recordings.isEmpty)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
		#expect(files.isEmpty)
	}

	@Test func savingSegmentsWhenKeepingIsOffStillRemovesTheParts() async throws {
		let scratch = Self.makeDirectory()
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		let part = scratch.appendingPathComponent("part.wav")
		try WAVFileWriter.write(samples: Self.samples(seconds: 1), sampleRate: 16000, to: part)
		let defaults = Self.makeDefaults()
		defaults.set(false, forKey: CancelledRecordingStore.keepRecordingsKey)
		let store = makeStore(defaults: defaults)

		let kept = await store.save(segments: [.init(url: part, channel: InputChannelSelection.mixAllChannels)])

		#expect(kept == nil)
		#expect(store.recordings.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: part.path))
	}

	@Test func turningKeepingOffDeletesExistingRecordings() async throws {
		let defaults = Self.makeDefaults()
		let store = makeStore(defaults: defaults)
		await store.save(samples: Self.samples(seconds: 1))
		await store.save(samples: Self.samples(seconds: 1))
		#expect(store.recordings.count == 2)

		store.setKeepsRecordings(false)

		#expect(!store.keepsRecordings)
		#expect(defaults.bool(forKey: CancelledRecordingStore.keepRecordingsKey) == false)
		#expect(store.recordings.isEmpty)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
		#expect(files.isEmpty)
		let index = try #require(defaults.data(forKey: CancelledRecordingStore.indexKey))
		#expect(try JSONDecoder().decode([CancelledRecording].self, from: index).isEmpty)
	}

	@Test func relaunchWithKeepingOffDeletesWhatWasKept() async throws {
		let directory = Self.makeDirectory()
		let defaults = Self.makeDefaults()
		await makeStore(directory: directory, defaults: defaults).save(samples: Self.samples(seconds: 1))
		defaults.set(false, forKey: CancelledRecordingStore.keepRecordingsKey)

		let reopened = makeStore(directory: directory, defaults: defaults)

		#expect(reopened.recordings.isEmpty)
		let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		#expect(files.isEmpty)
	}

	@Test func turningKeepingBackOnSavesAgain() async {
		let store = makeStore()
		store.setKeepsRecordings(false)
		store.setKeepsRecordings(true)
		#expect(await store.save(samples: Self.samples(seconds: 1)) != nil)
	}
}
