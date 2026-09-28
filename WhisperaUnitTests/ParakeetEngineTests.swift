import CoreML
import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct ParakeetModelTests {

	@Test func recognisesParakeetIDs() {
		#expect(ParakeetModel.isParakeetID("parakeet-tdt-0.6b-v3"))
		#expect(ParakeetModel.isParakeetID("parakeet-tdt-0.6b-v2"))
		#expect(!ParakeetModel.isParakeetID("openai_whisper-base"))
		#expect(!ParakeetModel.isParakeetID("custom:parakeet-tdt-0.6b-v3"))
	}

	@MainActor
	@Test func standardModelDetectionExcludesOtherEngines() {
		#expect(WhisperKitTranscriber.isStandardWhisperKitModel("openai_whisper-small.en"))
		#expect(!WhisperKitTranscriber.isStandardWhisperKitModel("parakeet-tdt-0.6b-v3"))
		#expect(!WhisperKitTranscriber.isStandardWhisperKitModel("custom:foo"))
	}

	@MainActor
	@Test func displayNamesComeFromTheModel() {
		#expect(
			WhisperKitTranscriber.getModelDisplayName(for: "parakeet-tdt-0.6b-v3")
				== ParakeetModel.v3.displayName)
		#expect(WhisperKitTranscriber.getModelDisplayName(for: "parakeet-tdt-0.6b-v2").contains("English"))
	}

	@Test func modelsLiveUnderWhisperaModelsFolder() {
		let base = URL(fileURLWithPath: "/tmp/WhisperaBase")
		#expect(
			ParakeetEngine.directory(for: .v3, modelsBase: base).path
				== "/tmp/WhisperaBase/models/FluidInference/parakeet-tdt-0.6b-v3-coreml")
		#expect(
			ParakeetEngine.directory(for: .v2, modelsBase: base).lastPathComponent
				== "parakeet-tdt-0.6b-v2-coreml")
		#expect(!ParakeetEngine.isDownloaded(.v3, modelsBase: base))
	}
}

struct ParakeetShortClipTests {
	@Test func shortClipsArePaddedWithTrailingSilenceToOneSecond() {
		let clip: [Float] = [0.5, -0.5, 0.25]
		let padded = ParakeetEngine.paddedToMinimumLength(clip)
		#expect(padded.count == ParakeetEngine.minimumSampleCount)
		#expect(Array(padded.prefix(3)) == clip)
		#expect(padded.dropFirst(3).allSatisfy { $0 == 0 })
	}

	@Test func clipsOfAtLeastOneSecondAreUntouched() {
		let clip = [Float](repeating: 0.1, count: ParakeetEngine.minimumSampleCount + 5)
		#expect(ParakeetEngine.paddedToMinimumLength(clip) == clip)
	}
}

@MainActor
struct SerialAsyncQueueTests {
	@MainActor final class Probe {
		var active = 0
		var maxActive = 0
		var order: [Int] = []
	}

	@Test func overlappingCallsNeverRunConcurrentlyAndKeepTheirOrder() async throws {
		let queue = SerialAsyncQueue()
		let probe = Probe()
		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0..<6 {
				group.addTask { @MainActor in
					_ = try await queue.run {
						probe.active += 1
						probe.maxActive = max(probe.maxActive, probe.active)
						probe.order.append(index)
						try await Task.sleep(for: .milliseconds(20))
						probe.active -= 1
						return index
					}
				}
			}
			try await group.waitForAll()
		}
		#expect(probe.maxActive == 1)
		#expect(probe.order.sorted() == Array(0..<6))
	}

	@Test func aFailedCallDoesNotBlockTheNextOne() async throws {
		struct Boom: Error {}
		let queue = SerialAsyncQueue()
		await #expect(throws: Boom.self) {
			_ = try await queue.run { () async throws -> Int in throw Boom() }
		}
		#expect(try await queue.run { 42 } == 42)
	}
}

struct ModelFolderRepairTests {
	private func makeFolder() throws -> (URL, URL) {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("ModelRepair-\(UUID().uuidString)", isDirectory: true)
		let folder = root.appendingPathComponent("parakeet", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data("old".utf8).write(to: folder.appendingPathComponent("Encoder.bin"))
		return (root, folder)
	}

	@Test func failedDownloadPutsTheOldModelBack() async throws {
		let (root, folder) = try makeFolder()
		defer { try? FileManager.default.removeItem(at: root) }
		struct Offline: Error {}

		await #expect(throws: Offline.self) {
			try await ModelFolderRepair.replace(folder) {
				// A partial download must not survive either
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
				try Data("partial".utf8).write(to: folder.appendingPathComponent("Encoder.bin"))
				throw Offline()
			}
		}
		let restored = try String(contentsOf: folder.appendingPathComponent("Encoder.bin"), encoding: .utf8)
		#expect(restored == "old")
		#expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["parakeet"])
	}

	@Test func successfulDownloadReplacesTheOldModel() async throws {
		let (root, folder) = try makeFolder()
		defer { try? FileManager.default.removeItem(at: root) }

		try await ModelFolderRepair.replace(folder) {
			#expect(!FileManager.default.fileExists(atPath: folder.path))
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try Data("new".utf8).write(to: folder.appendingPathComponent("Encoder.bin"))
		}
		let replaced = try String(contentsOf: folder.appendingPathComponent("Encoder.bin"), encoding: .utf8)
		#expect(replaced == "new")
		#expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["parakeet"])
	}
}

@MainActor
struct ParakeetLoadSafetyTests {
	/// FluidAudio's loader deletes the folder after a failed load; Whispera's must leave it alone.
	@Test func failedLoadWithoutRepairKeepsTheModelOnDisk() async throws {
		let base = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetLoad-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		let folder = ParakeetEngine.directory(for: .v3, modelsBase: base)
		for name in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
			let model = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
			try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
			try Data("not a model".utf8).write(to: model.appendingPathComponent("coremldata.bin"))
		}
		try Data(#"{"0":"a"}"#.utf8).write(to: folder.appendingPathComponent("parakeet_vocab.json"))
		#expect(ParakeetEngine.isDownloaded(.v3, modelsBase: base))

		await #expect(throws: (any Error).self) {
			_ = try await ParakeetEngine.load(.v3, modelsBase: base, computeUnits: .cpuOnly, repairIfCorrupt: false)
		}
		#expect(ParakeetEngine.isDownloaded(.v3, modelsBase: base))
	}

	@Test func missingModelIsReportedWithoutDownloading() async throws {
		let base = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetMissing-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		await #expect(throws: ParakeetLoadError.notDownloaded(ParakeetModel.v3.displayName)) {
			_ = try await ParakeetEngine.load(.v3, modelsBase: base, computeUnits: nil)
		}
		#expect(!FileManager.default.fileExists(atPath: ParakeetEngine.directory(for: .v3, modelsBase: base).path))
	}

	@Test func vocabularyParsesTokenIDs() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }
		try Data(#"{"0":"<unk>","5":"▁the","x":"skip"}"#.utf8).write(to: url)
		#expect(try ParakeetEngine.vocabulary(at: url) == [0: "<unk>", 5: "▁the"])
	}
}

struct TranscriptSegmenterTests {

	private func tokens(_ spec: [(String, Double, Double)]) -> [TimedToken] {
		spec.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) }
	}

	@Test func emptyInputYieldsNoSegments() {
		#expect(TranscriptSegmenter.segments(from: []).isEmpty)
	}

	@Test func joinsSubwordPiecesAndSplitsOnSentenceEnd() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([
				(" Hel", 0.0, 0.2), ("lo", 0.2, 0.4), (" there.", 0.4, 0.8),
				(" How", 1.0, 1.2), (" are", 1.2, 1.4), (" you?", 1.4, 1.8),
			]))
		#expect(segments.map(\.text) == ["Hello there.", "How are you?"])
		#expect(segments.map(\.startTime) == [0.0, 1.0])
		#expect(segments.map(\.endTime) == [0.8, 1.8])
	}

	@Test func splitsOnLongPauses() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([(" one", 0, 0.3), (" two", 3.0, 3.3)]), pauseThreshold: 1.0)
		#expect(segments.map(\.text) == ["one", "two"])
	}

	@Test func doesNotSplitInsideAWord() {
		let segments = TranscriptSegmenter.segments(
			from: tokens([(" Dr.", 0, 0.3), ("ive", 5.0, 5.3)]), pauseThreshold: 1.0)
		#expect(segments.map(\.text) == ["Dr.ive"])
	}

	@Test func capsSegmentDuration() {
		let words = (0..<10).map { (" w\($0)", Double($0), Double($0) + 0.5) }
		let segments = TranscriptSegmenter.segments(from: tokens(words), maxSegmentDuration: 4)
		#expect(segments.count == 3)
		#expect(segments.first?.text == "w0 w1 w2 w3")
	}
}

/// Real Parakeet transcription through FluidAudio. Runs when the v3 model is already downloaded, or when
/// WHISPERA_PARAKEET_E2E=1 (TEST_RUNNER_WHISPERA_PARAKEET_E2E=1 via xcodebuild) allows downloading it.
@MainActor
struct ParakeetTranscriptionTests {

	nonisolated static let modelsBase = FileManager.default.urls(
		for: .applicationSupportDirectory, in: .userDomainMask
	)[0].appendingPathComponent("Whispera", isDirectory: true)

	nonisolated static var enabled: Bool {
		ParakeetEngine.isDownloaded(.v3, modelsBase: modelsBase)
			|| ProcessInfo.processInfo.environment["WHISPERA_PARAKEET_E2E"] == "1"
	}

	@Test(.enabled(if: enabled, "Parakeet v3 not downloaded; set WHISPERA_PARAKEET_E2E=1"))
	func transcribesSpeechFromFileAndSamples() async throws {
		if !ParakeetEngine.isDownloaded(.v3, modelsBase: Self.modelsBase) {
			try await ParakeetEngine.download(.v3, modelsBase: Self.modelsBase)
		}
		let engine = try await ParakeetEngine.load(
			.v3, modelsBase: Self.modelsBase, computeUnits: nil)
		defer { engine.unload() }

		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetE2E-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make(
			"The quick brown fox jumps over the lazy dog. Then it runs into the forest.", in: directory)

		let fromFile = try await engine.transcribe(fileURL: audio)
		let lowered = fromFile.text.lowercased()
		#expect(lowered.contains("fox"))
		#expect(lowered.contains("forest"))
		#expect(!fromFile.segments.isEmpty)
		#expect((fromFile.segments.last?.endTime ?? 0) > 1)

		let cpuEngine = try await ParakeetEngine.load(
			.v3, modelsBase: Self.modelsBase, computeUnits: .cpuOnly)
		defer { cpuEngine.unload() }
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
		let fromSamples = try await cpuEngine.transcribe(samples: samples)
		#expect(fromSamples.text.lowercased().contains("fox"))
	}

	private func loadedEngine() async throws -> ParakeetEngine {
		if !ParakeetEngine.isDownloaded(.v3, modelsBase: Self.modelsBase) {
			try await ParakeetEngine.download(.v3, modelsBase: Self.modelsBase)
		}
		return try await ParakeetEngine.load(.v3, modelsBase: Self.modelsBase, computeUnits: nil)
	}

	@Test(.enabled(if: enabled, "Parakeet v3 not downloaded; set WHISPERA_PARAKEET_E2E=1"))
	func transcribesAOneWordClipShorterThanOneSecond() async throws {
		let engine = try await loadedEngine()
		defer { engine.unload() }
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetShort-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let audio = try SpeechFixture.make("Yes.", in: directory)
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
		#expect(samples.count < ParakeetEngine.minimumSampleCount)

		let fromSamples = try await engine.transcribe(samples: samples)
		#expect(fromSamples.text.lowercased().contains("yes"))
		let fromFile = try await engine.transcribe(fileURL: audio)
		#expect(fromFile.text.lowercased().contains("yes"))
	}

	@Test(.enabled(if: enabled, "Parakeet v3 not downloaded; set WHISPERA_PARAKEET_E2E=1"))
	func overlappingTranscriptionsOnOneEngineStayIndependent() async throws {
		let engine = try await loadedEngine()
		defer { engine.unload() }
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ParakeetOverlap-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try AudioProcessor.loadAudioAsFloatArray(
			fromPath: try SpeechFixture.make("The quick brown fox jumps over the lazy dog.", in: directory).path)
		let second = try AudioProcessor.loadAudioAsFloatArray(
			fromPath: try SpeechFixture.make("Please send the invoice to the accounting team.", in: directory).path)

		for _ in 0..<3 {
			async let a = engine.transcribe(samples: first)
			async let b = engine.transcribe(samples: second)
			async let c = engine.transcribe(samples: first)
			let (textA, textB, textC) = try await (a.text.lowercased(), b.text.lowercased(), c.text.lowercased())
			#expect(textA.contains("fox") && textA.contains("lazy dog"))
			#expect(textB.contains("invoice") && textB.contains("accounting"))
			#expect(textC == textA)
		}
	}
}
