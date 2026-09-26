import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct NeuralVoiceActivityTrimmerTests {
	private let chunk = 4096

	/// Loudness rising and falling four times a second, like syllables.
	private func syllables(count: Int) -> [Float] {
		(0..<count).map { index in
			let envelope = 0.05 + 0.2 * abs(sin(Float.pi * 4 * Float(index) / 16000))
			return envelope * sin(2 * Float.pi * 220 * Float(index) / 16000)
		}
	}

	/// Constant level, like a fan or white hiss.
	private func steady(count: Int) -> [Float] {
		(0..<count).map { 0.1 * sin(2 * Float.pi * 220 * Float($0) / 16000) }
	}

	@Test func trimsToTheSpeechChunksWithPadding() {
		let samples = syllables(count: chunk * 6)
		var trimmer = NeuralVoiceActivityTrimmer(sensitivity: .medium)
		trimmer.padding = 0.1
		let result = trimmer.trim(samples, probabilities: [0.05, 0.1, 0.9, 0.7, 0.2, 0.05])

		guard case .speech(let trimmed) = result else {
			Issue.record("Expected speech, got \(result)")
			return
		}
		let padding = 1600
		#expect(trimmed.count == (4 - 2) * chunk + 2 * padding)
	}

	@Test func quietProbabilitiesMeanNoSpeech() {
		let samples = syllables(count: chunk * 3)
		#expect(
			NeuralVoiceActivityTrimmer(sensitivity: .medium).trim(samples, probabilities: [0.1, 0.4, 0.2]) == .noSpeech)
	}

	@Test func sensitivityMovesTheThreshold() {
		let samples = syllables(count: chunk * 2)
		let probabilities: [Float] = [0.1, 0.4]
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .low).trim(samples, probabilities: probabilities) == .noSpeech)
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .high).trim(samples, probabilities: probabilities) != .noSpeech)
		#expect(VADSensitivity.high.neuralThreshold < VADSensitivity.medium.neuralThreshold)
		#expect(VADSensitivity.medium.neuralThreshold < VADSensitivity.low.neuralThreshold)
	}

	@Test func emptyClipHasNoSpeech() {
		#expect(NeuralVoiceActivityTrimmer().trim([], probabilities: []) == .noSpeech)
	}

	/// Silero scores white hiss up to 0.98 on single chunks; a steady level is never speech.
	@Test func steadyAudioIsNotSpeechEvenWhenAChunkScoresHigh() {
		let samples = steady(count: chunk * 6)
		let probabilities: [Float] = [0.2, 0.3, 0.98, 0.95, 0.4, 0.2]
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .medium).trim(samples, probabilities: probabilities) == .noSpeech)
		#expect(NeuralVoiceActivityTrimmer(sensitivity: .high).trim(samples, probabilities: probabilities) == .noSpeech)
	}

	@Test func steadyNoiseSegmentsAroundSpeechAreLeftOut() {
		let samples = steady(count: chunk * 2) + syllables(count: chunk * 2) + steady(count: chunk * 2)
		var trimmer = NeuralVoiceActivityTrimmer(sensitivity: .medium)
		trimmer.padding = 0
		let result = trimmer.trim(samples, probabilities: [0.9, 0.1, 0.1, 0.99, 0.1, 0.8])

		guard case .speech(let trimmed) = result else {
			Issue.record("Expected speech, got \(result)")
			return
		}
		#expect(trimmed == Array(samples[(3 * chunk)..<(4 * chunk)]))
	}

	/// Silero keeps a segment open until the probability drops 0.15 below the threshold.
	@Test func hysteresisKeepsTheSegmentOpenThroughADip() {
		let trimmer = NeuralVoiceActivityTrimmer(sensitivity: .medium)
		#expect(trimmer.segments([0.1, 0.9, 0.4, 0.8, 0.3, 0.1]) == [1..<4])
		#expect(trimmer.segments([0.1, 0.9, 0.2, 0.8, 0.1]) == [1..<2, 3..<4])
		#expect(trimmer.segments([0.6, 0.6]) == [0..<2])
	}

	@Test func partlySilentAudioCountsAsModulated() {
		let trimmer = NeuralVoiceActivityTrimmer()
		let samples = [Float](repeating: 0, count: 3200) + steady(count: 3200)
		#expect(trimmer.loudnessSwing(samples[...]) == .infinity)
		#expect(trimmer.loudnessSwing(steady(count: 3200)[...]) < 1.1)
		#expect(trimmer.loudnessSwing([Float](repeating: 0, count: 3200)[...]) == 0)
	}
}

struct VADEngineSettingsTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "VADEngineSettingsTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToTheEnergyDetector() {
		#expect(VoiceActivitySettings(defaults: makeDefaults()).engine == .energy)
	}

	@Test func readsTheNeuralChoice() {
		let defaults = makeDefaults()
		defaults.set(VADEngine.neural.rawValue, forKey: VADEngine.defaultsKey)
		#expect(VoiceActivitySettings(defaults: defaults).engine == .neural)
		defaults.set("earshot", forKey: VADEngine.defaultsKey)
		#expect(VoiceActivitySettings(defaults: defaults).engine == .energy)
	}
}

/// Runs the real Silero model through FluidAudio; the first run downloads it from Hugging Face.
struct NeuralVoiceActivityModelTests {
	static let speechURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("WhisperaTests/Resources/bush_radio_address.wav")

	private func speech(seconds: Double) throws -> [Float] {
		let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: Self.speechURL.path)
		return Array(samples.prefix(Int(seconds * 16000)))
	}

	/// Steady hiss well above the energy detector's absolute floor.
	private func hiss(seconds: Double) -> [Float] {
		var generator = SystemRandomNumberGenerator()
		return (0..<Int(seconds * 16000)).map { _ in Float.random(in: -0.05...0.05, using: &generator) }
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func detectsRealSpeech() async throws {
		let clip = try speech(seconds: 8)
		let result = try await NeuralVoiceActivityDetector.shared.process(clip, sensitivity: .medium)
		guard case .speech(let trimmed) = result else {
			Issue.record("Silero found no speech in a real recording")
			return
		}
		#expect(trimmed.count > clip.count / 2)
		#expect(NeuralVoiceActivityDetector.isDownloaded)
	}

	@Test(.timeLimit(.minutes(5)))
	func steadyNoiseIsNotSpeech() async throws {
		let noise = hiss(seconds: 3)
		#expect(try await NeuralVoiceActivityDetector.shared.process(noise, sensitivity: .medium) == .noSpeech)
	}

	/// Many independent hiss clips at several levels, because Silero's score on hiss is random
	/// per chunk and the old any-chunk rule let about 4 in 10 through.
	@Test(.timeLimit(.minutes(5)))
	func manyHissClipsAreNotSpeechAtAnySensitivity() async throws {
		var generator = SystemRandomNumberGenerator()
		for amplitude: Float in [0.02, 0.05, 0.1, 0.3] {
			for _ in 0..<10 {
				let noise = (0..<48000).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
				for sensitivity in VADSensitivity.allCases {
					let result = try await NeuralVoiceActivityDetector.shared.process(noise, sensitivity: sensitivity)
					#expect(result == .noSpeech, "hiss at \(amplitude) passed as speech at \(sensitivity)")
				}
			}
		}
	}

	private static let resources = speechURL.deletingLastPathComponent()

	private func word(_ name: String) throws -> [Float] {
		try AudioProcessor.loadAudioAsFloatArray(
			fromPath: Self.resources.appendingPathComponent("vad/\(name).wav").path)
	}

	/// Single spoken words of about half a second, placed at every quarter of a Silero chunk,
	/// at full level, quiet, and under hiss, so short answers are never dropped.
	@Test(
		.enabled(
			if: FileManager.default.fileExists(atPath: resources.appendingPathComponent("vad/yes.wav").path),
			"Needs the bundled word recordings"),
		.timeLimit(.minutes(5)))
	func detectsShortSingleWords() async throws {
		var generator = SystemRandomNumberGenerator()
		for name in ["yes", "no", "stop", "okay"] {
			let spoken = try word(name)
			for offset in stride(from: 0, to: 4096, by: 1024) {
				let clip = [Float](repeating: 0, count: 16000 + offset) + spoken + [Float](repeating: 0, count: 16000)
				let variants: [(String, [Float])] = [
					("full", clip),
					("quiet", clip.map { $0 * 0.02 }),
					("in hiss", clip.map { $0 * 0.3 + Float.random(in: -0.03...0.03, using: &generator) }),
				]
				for (label, samples) in variants {
					let result = try await NeuralVoiceActivityDetector.shared.process(samples, sensitivity: .medium)
					#expect(result != .noSpeech, "'\(name)' \(label) at offset \(offset) was dropped")
				}
			}
		}
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func detectsHalfSecondSlicesOfRealSpeech() async throws {
		let recording = try AudioProcessor.loadAudioAsFloatArray(fromPath: Self.speechURL.path)
		let silence = [Float](repeating: 0, count: 16000)
		for start in [1.0, 4.0] {
			let from = Int(start * 16000)
			let clip = silence + Array(recording[from..<(from + 8000)]) + silence
			let result = try await NeuralVoiceActivityDetector.shared.process(clip, sensitivity: .medium)
			#expect(result != .noSpeech, "half a second of speech at \(start) s was dropped")
		}
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func detectsQuietAndNoisySpeech() async throws {
		let clip = try speech(seconds: 8)
		var generator = SystemRandomNumberGenerator()
		let quiet = clip.map { $0 * 0.01 }
		let noisy = clip.map { $0 * 0.3 + Float.random(in: -0.05...0.05, using: &generator) }
		#expect(try await NeuralVoiceActivityDetector.shared.process(quiet, sensitivity: .medium) != .noSpeech)
		#expect(try await NeuralVoiceActivityDetector.shared.process(noisy, sensitivity: .medium) != .noSpeech)
	}

	/// A notification beep between silences: loud enough for the energy detector, but not a voice.
	@Test(.timeLimit(.minutes(5)))
	func beepIsNotSpeechForTheModelButIsForEnergy() async throws {
		let silence = [Float](repeating: 0, count: 16000)
		let beep = (0..<16000).map { 0.3 * sin(2 * Float.pi * 1000 * Float($0) / 16000) }
		let clip = silence + beep + silence

		#expect(VoiceActivityTrimmer(sensitivity: .medium).process(clip) != .noSpeech)
		#expect(try await NeuralVoiceActivityDetector.shared.process(clip, sensitivity: .medium) == .noSpeech)
	}

	@Test(
		.enabled(if: FileManager.default.fileExists(atPath: speechURL.path), "Needs the bundled test recording"),
		.timeLimit(.minutes(5)))
	func trimsSilenceAroundSpeech() async throws {
		let clip = try speech(seconds: 4)
		let silence = [Float](repeating: 0, count: 3 * 16000)
		let padded = silence + clip + silence

		let result = try await NeuralVoiceActivityDetector.shared.process(padded, sensitivity: .medium)

		guard case .speech(let trimmed) = result else {
			Issue.record("Silero found no speech in padded speech")
			return
		}
		#expect(trimmed.count < padded.count - 3 * 16000)
		#expect(trimmed.count >= Int(Double(clip.count) * 0.6))
	}
}
