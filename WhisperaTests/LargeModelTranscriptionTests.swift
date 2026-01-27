import AVFoundation
import XCTest

@testable import Whispera

/// Integration tests for large model transcription with sampleLength = 224 fix.
/// These tests verify that the KV cache overflow fix works correctly.
@MainActor
final class LargeModelTranscriptionTests: XCTestCase {

	var transcriber: WhisperKitTranscriber!

	override func setUp() async throws {
		transcriber = WhisperKitTranscriber.shared
	}

	override func tearDown() async throws {
		transcriber = nil
	}

	// MARK: - sampleLength Configuration Tests

	func testSampleLengthDefaultIs224() async throws {
		// Given
		let transcriber = WhisperKitTranscriber.shared

		// When
		let options = transcriber.createDecodingOptions(enableTranslation: false)

		// Then
		XCTAssertEqual(
			options.sampleLength, 224,
			"sampleLength should default to 224 to prevent KV cache overflow"
		)
	}

	func testSampleLengthIs224WithTranslation() async throws {
		// Given
		let transcriber = WhisperKitTranscriber.shared

		// When
		let options = transcriber.createDecodingOptions(enableTranslation: true)

		// Then
		XCTAssertEqual(
			options.sampleLength, 224,
			"sampleLength should be 224 even with translation enabled"
		)
	}

	func testDecodingOptionsStatusIncludesSampleLength() async throws {
		// Given
		let transcriber = WhisperKitTranscriber.shared

		// When
		let status = transcriber.getDecodingOptionsStatus()

		// Then
		guard let sampleLength = status["sampleLength"] as? Int else {
			XCTFail("sampleLength should be present in decoding options status")
			return
		}

		XCTAssertEqual(
			sampleLength, 224,
			"sampleLength in status should be 224"
		)
	}

	func testResetDecodingOptionsSetsSampleLengthTo224() async throws {
		// Given
		let transcriber = WhisperKitTranscriber.shared

		// When
		transcriber.resetDecodingOptionsToDefaults()
		let options = transcriber.createDecodingOptions(enableTranslation: false)

		// Then
		XCTAssertEqual(
			options.sampleLength, 224,
			"After reset, sampleLength should be 224"
		)
	}

	// MARK: - Optimized Compute Options Tests

	func testMelComputeUsesCPUAndGPU() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let status = transcriber.getComputeOptionsStatus()

		XCTAssertEqual(
			status["melCompute"], "cpuAndGPU",
			"melCompute should use CPU and GPU for feature extraction"
		)
	}

	func testAudioEncoderComputeUsesCPUAndGPU() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let status = transcriber.getComputeOptionsStatus()

		XCTAssertEqual(
			status["audioEncoderCompute"], "cpuAndGPU",
			"audioEncoderCompute should use CPU and GPU"
		)
	}

	func testTextDecoderComputeUsesCPUAndNeuralEngine() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let status = transcriber.getComputeOptionsStatus()

		XCTAssertEqual(
			status["textDecoderCompute"], "cpuAndNeuralEngine",
			"textDecoderCompute should use CPU and Neural Engine for optimal performance"
		)
	}

	func testPrefillComputeUsesCPUAndGPU() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let status = transcriber.getComputeOptionsStatus()

		XCTAssertEqual(
			status["prefillCompute"], "cpuAndGPU",
			"prefillCompute should use CPU and GPU"
		)
	}

	func testAllComputeOptionsAreConfigured() async throws {
		let transcriber = WhisperKitTranscriber.shared
		let status = transcriber.getComputeOptionsStatus()

		XCTAssertNotNil(status["melCompute"], "melCompute should be configured")
		XCTAssertNotNil(status["audioEncoderCompute"], "audioEncoderCompute should be configured")
		XCTAssertNotNil(status["textDecoderCompute"], "textDecoderCompute should be configured")
		XCTAssertNotNil(status["prefillCompute"], "prefillCompute should be configured")
	}

	// MARK: - Model Loading Integration Tests

	/// This test actually loads a model and transcribes audio.
	/// It requires a downloaded model and is slow - use for integration testing only.
	func testTranscriptionWithTinyModelDoesNotCrash() async throws {
		// Skip if no models are downloaded
		let downloadedModels = try await transcriber.getDownloadedModels()
		try XCTSkipIf(downloadedModels.isEmpty, "No models downloaded - skipping integration test")

		// Prefer tiny model for speed, fall back to any available model
		let modelToUse = downloadedModels.first { $0.contains("tiny") } ?? downloadedModels.first!

		// Given: Wait for initialization
		let initTimeout: UInt64 = 30_000_000_000  // 30 seconds
		let startTime = DispatchTime.now()

		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
			let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
			if elapsed > initTimeout {
				XCTFail("WhisperKit initialization timed out")
				return
			}
		}

		// When: Load model
		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model \(modelToUse): \(error.localizedDescription)")
		}

		// Create test audio (1 second of silence - won't produce speech but tests the pipeline)
		let testAudio = createSilentAudioSamples(durationSeconds: 1.0)

		// Then: Transcription should complete without crashing
		do {
			let result = try await transcriber.transcribeAudioArray(testAudio, enableTranslation: false)
			XCTAssertNotNil(result, "Should return a result (even if 'no speech detected')")
		} catch {
			XCTFail("Transcription failed with error: \(error.localizedDescription)")
		}
	}

	/// Tests that larger models (small, medium, large) don't crash with sampleLength = 224.
	/// This is the main regression test for the KV cache overflow fix.
	func testLargeModelTranscriptionWithSampleLength224() async throws {
		let downloadedModels = try await transcriber.getDownloadedModels()

		// Look for a larger model (small or above)
		let largerModels = downloadedModels.filter {
			$0.contains("small") || $0.contains("medium") || $0.contains("large")
		}

		try XCTSkipIf(largerModels.isEmpty, "No larger models downloaded - skipping integration test")

		let modelToUse = largerModels.first!

		// Wait for initialization
		let initTimeout: UInt64 = 30_000_000_000
		let startTime = DispatchTime.now()

		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)
			let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
			if elapsed > initTimeout {
				XCTFail("WhisperKit initialization timed out")
				return
			}
		}

		// Load the larger model
		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model \(modelToUse): \(error.localizedDescription)")
		}

		// Verify sampleLength is 224 before transcription
		let options = transcriber.createDecodingOptions(enableTranslation: false)
		XCTAssertEqual(options.sampleLength, 224, "sampleLength must be 224 for large models")

		// Create longer test audio to stress the KV cache
		let testAudio = createSilentAudioSamples(durationSeconds: 5.0)

		// This should NOT crash with "Could not store NSNumber at offset" error
		do {
			let result = try await transcriber.transcribeAudioArray(testAudio, enableTranslation: false)
			XCTAssertNotNil(result, "Large model transcription should complete without KV cache crash")
		} catch {
			let errorString = error.localizedDescription

			// These specific errors indicate the sampleLength fix isn't working
			if errorString.contains("Could not store NSNumber at offset")
				|| errorString.contains("beyond the end of the multi array")
			{
				XCTFail(
					"KV cache overflow detected - sampleLength fix may not be applied: \(errorString)")
			} else {
				// Other errors might be acceptable (e.g., model issues, memory)
				XCTFail("Transcription failed: \(errorString)")
			}
		}
	}

	/// Tests transcription with a real audio file containing speech.
	func testTranscriptionWithGeneratedSpeechAudio() async throws {
		let downloadedModels = try await transcriber.getDownloadedModels()
		try XCTSkipIf(downloadedModels.isEmpty, "No models downloaded - skipping integration test")

		let modelToUse = downloadedModels.first { $0.contains("tiny") } ?? downloadedModels.first!

		// Wait for initialization
		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)
		}

		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model: \(error.localizedDescription)")
		}

		// Create test audio file
		let audioURL = createTestAudioFile()
		defer { try? FileManager.default.removeItem(at: audioURL) }

		// Transcribe file
		do {
			let result = try await transcriber.transcribe(audioURL: audioURL, enableTranslation: false)
			XCTAssertNotNil(result, "Should return transcription result")
		} catch {
			XCTFail("File transcription failed: \(error.localizedDescription)")
		}
	}

	// MARK: - Stress Tests

	/// Tests multiple consecutive transcriptions don't cause memory issues or crashes.
	func testConsecutiveTranscriptionsWithSampleLength224() async throws {
		let downloadedModels = try await transcriber.getDownloadedModels()
		try XCTSkipIf(downloadedModels.isEmpty, "No models downloaded - skipping stress test")

		let modelToUse = downloadedModels.first { $0.contains("tiny") } ?? downloadedModels.first!

		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)
		}

		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model: \(error.localizedDescription)")
		}

		let testAudio = createSilentAudioSamples(durationSeconds: 2.0)

		// Run multiple transcriptions
		for i in 1...5 {
			do {
				let result = try await transcriber.transcribeAudioArray(
					testAudio, enableTranslation: false)
				XCTAssertNotNil(result, "Transcription \(i) should complete")
			} catch {
				XCTFail("Transcription \(i) failed: \(error.localizedDescription)")
				break
			}
		}
	}

	// MARK: - Real Speech Transcription Tests

	/// Tests transcription accuracy with George W. Bush's January 27, 2001 Radio Address.
	/// This test verifies the sampleLength=224 fix works with real speech audio.
	/// Audio source: https://upload.wikimedia.org/wikipedia/commons/6/6e/George_W._Bush_Radio_Address_%28January_27%2C_2001%29.ogg
	func testTranscriptionWithRealSpeechAudio() async throws {
		let downloadedModels = try await transcriber.getDownloadedModels()
		try XCTSkipIf(downloadedModels.isEmpty, "No models downloaded - skipping real speech test")

		let modelToUse = downloadedModels.first { $0.contains("base") || $0.contains("small") }
			?? downloadedModels.first!

		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)
		}

		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model: \(error.localizedDescription)")
		}

		let audioURL = getBushRadioAddressURL()
		try XCTSkipIf(
			!FileManager.default.fileExists(atPath: audioURL.path),
			"Test audio file not found at \(audioURL.path)"
		)

		let options = transcriber.createDecodingOptions(enableTranslation: false)
		XCTAssertEqual(options.sampleLength, 224, "sampleLength must be 224 for this test")

		do {
			let result = try await transcriber.transcribe(audioURL: audioURL, enableTranslation: false)

			XCTAssertNotNil(result, "Should return transcription result")
			XCTAssertFalse(result.isEmpty, "Transcription should not be empty")

			// Write transcript to file for inspection
			let outputPath = "/tmp/whispera_transcription_output.txt"
			try? result.write(toFile: outputPath, atomically: true, encoding: .utf8)
			print("Transcript written to: \(outputPath)")

			let transcriptLower = result.lowercased()

			// Expected keywords from Bush's January 27, 2001 Radio Address about education reform
			let expectedKeywords = [
				"education",
				"school",
				"children",
				"congress",
				"reform",
			]

			var foundKeywords: [String] = []
			for keyword in expectedKeywords {
				if transcriptLower.contains(keyword) {
					foundKeywords.append(keyword)
				}
			}

			print("Found keywords: \(foundKeywords)")

			XCTAssertGreaterThanOrEqual(
				foundKeywords.count, 2,
				"Should recognize at least 2 keywords from the speech. Found: \(foundKeywords). Transcript: \(result.prefix(500))..."
			)

		} catch {
			XCTFail("Real speech transcription failed: \(error.localizedDescription)")
		}
	}

	/// Tests that longer audio (3+ minutes) transcribes without KV cache crashes.
	func testLongAudioTranscriptionWithSampleLength224() async throws {
		let downloadedModels = try await transcriber.getDownloadedModels()
		try XCTSkipIf(downloadedModels.isEmpty, "No models downloaded")

		let modelToUse = downloadedModels.first { $0.contains("tiny") } ?? downloadedModels.first!

		while !transcriber.isInitialized {
			try await Task.sleep(nanoseconds: 100_000_000)
		}

		do {
			try await transcriber.switchModel(to: modelToUse)
		} catch {
			throw XCTSkip("Could not load model: \(error.localizedDescription)")
		}

		let audioURL = getBushRadioAddressURL()
		try XCTSkipIf(
			!FileManager.default.fileExists(atPath: audioURL.path),
			"Test audio file not found"
		)

		do {
			let result = try await transcriber.transcribe(audioURL: audioURL, enableTranslation: false)
			XCTAssertNotNil(result, "Long audio transcription should complete without crash")
			XCTAssertFalse(result.isEmpty, "Transcription should produce text")
		} catch {
			let errorString = error.localizedDescription
			if errorString.contains("Could not store NSNumber at offset")
				|| errorString.contains("beyond the end of the multi array")
			{
				XCTFail("KV cache overflow on long audio - sampleLength fix not working: \(errorString)")
			} else {
				XCTFail("Long audio transcription failed: \(errorString)")
			}
		}
	}

	// MARK: - Helper Methods

	private func getBushRadioAddressURL() -> URL {
		let bundle = Bundle(for: type(of: self))
		if let url = bundle.url(forResource: "bush_radio_address", withExtension: "wav") {
			return url
		}
		return URL(
			fileURLWithPath:
				"/Users/ismatullamansurov/Developer/whispera/WhisperaTests/Resources/bush_radio_address.wav"
		)
	}

	private func createSilentAudioSamples(durationSeconds: Float) -> [Float] {
		let sampleRate: Float = 16000
		let sampleCount = Int(sampleRate * durationSeconds)
		return Array(repeating: 0.0, count: sampleCount)
	}

	private func createTestAudioFile() -> URL {
		let tempDir = FileManager.default.temporaryDirectory
		let fileName = "test_audio_\(UUID().uuidString).wav"
		let audioURL = tempDir.appendingPathComponent(fileName)

		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 16000.0,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsFloatKey: false,
		]

		do {
			let audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
			let frameCount = AVAudioFrameCount(16000 * 1)  // 1 second
			let buffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
			buffer.frameLength = frameCount

			// Add a simple tone to make it more realistic
			if let channelData = buffer.floatChannelData?[0] {
				for i in 0..<Int(frameCount) {
					let time = Float(i) / 16000.0
					channelData[i] = sin(2.0 * Float.pi * 440.0 * time) * 0.1
				}
			}

			try audioFile.write(from: buffer)
		} catch {
			print("Failed to create test audio file: \(error)")
		}

		return audioURL
	}
}
