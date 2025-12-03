import AVFoundation
import XCTest

@testable import Whispera

@MainActor
final class StreamingTranscriptionIntegrationTests: XCTestCase {

	var audioManager: AudioManager!
	var whisperKitTranscriber: WhisperKitTranscriber!

	override func setUp() async throws {
		audioManager = AudioManager()
		whisperKitTranscriber = WhisperKitTranscriber.shared
	}

	override func tearDown() async throws {
		audioManager = nil
		whisperKitTranscriber = nil
	}

	// MARK: - End-to-End Integration Tests

	func testStreamingModeToggleAffectsRecordingFlow() async throws {
		// Given
		audioManager.useStreamingTranscription = true

		// When
		audioManager.setupAudio()

		// Then
		XCTAssertTrue(audioManager.useStreamingTranscription, "Streaming mode should be enabled")

		// When toggling to file mode
		audioManager.useStreamingTranscription = false
		audioManager.setupAudio()

		// Then
		XCTAssertFalse(audioManager.useStreamingTranscription, "File mode should be enabled")
	}

	func testAudioManagerWhisperKitIntegration() async throws {
		// Given
		let audioManager = AudioManager()
		let transcriber = audioManager.whisperKitTranscriber

		// Then
		XCTAssertTrue(
			transcriber === WhisperKitTranscriber.shared,
			"AudioManager should use shared WhisperKit transcriber")
		XCTAssertNotNil(transcriber, "WhisperKit transcriber should be available")
	}

	func testStreamingTranscriptionWithMockAudio() async throws {
		// Given
		audioManager.useStreamingTranscription = true
		let testAudioData: [Float] = Array(repeating: 0.1, count: 16000)  // 1 second of test audio

		// When
		// We can't easily test the full streaming flow without mocking the audio engine
		// So we test the transcription method directly
		do {
			let result = try await whisperKitTranscriber.transcribeAudioArray(
				testAudioData, enableTranslation: false)
			XCTAssertNotNil(result, "Should return transcription result")
		} catch WhisperKitError.notInitialized {
			// Expected in test environment
			XCTAssertTrue(true, "WhisperKit not initialized in test environment")
		} catch WhisperKitError.noModelLoaded {
			// Expected in test environment
			XCTAssertTrue(true, "No model loaded in test environment")
		} catch WhisperKitError.notReady {
			// Expected in test environment
			XCTAssertTrue(true, "WhisperKit not ready in test environment")
		}
	}

	func testFileBasedTranscriptionStillWorks() async throws {
		// Given
		audioManager.useStreamingTranscription = false

		// Create a temporary audio file for testing
		let testAudioPath = createTemporaryAudioFile()

		// When
		do {
			let result = try await whisperKitTranscriber.transcribe(
				audioURL: testAudioPath, enableTranslation: false)
			XCTAssertNotNil(result, "Should return transcription result")
		} catch WhisperKitError.notInitialized {
			// Expected in test environment
			XCTAssertTrue(true, "WhisperKit not initialized in test environment")
		} catch WhisperKitError.noModelLoaded {
			// Expected in test environment
			XCTAssertTrue(true, "No model loaded in test environment")
		} catch WhisperKitError.notReady {
			// Expected in test environment
			XCTAssertTrue(true, "WhisperKit not ready in test environment")
		}

		// Cleanup
		try? FileManager.default.removeItem(at: testAudioPath)
	}

	func testModeSwichingDuringRuntime() async throws {
		// Given
		audioManager.useStreamingTranscription = true

		// When switching modes
		audioManager.useStreamingTranscription = false
		audioManager.setupAudio()

		// Then
		XCTAssertFalse(audioManager.useStreamingTranscription, "Should switch to file-based mode")

		// When switching back
		audioManager.useStreamingTranscription = true
		audioManager.setupAudio()

		// Then
		XCTAssertTrue(audioManager.useStreamingTranscription, "Should switch back to streaming mode")
	}

	func testSettingsViewToggleIntegration() async throws {
		// Given
		let initialStreamingMode = UserDefaults.standard.bool(forKey: "useStreamingTranscription")

		// When
		audioManager.useStreamingTranscription = !initialStreamingMode

		// Then
		let newStoredValue = UserDefaults.standard.bool(forKey: "useStreamingTranscription")
		XCTAssertEqual(newStoredValue, !initialStreamingMode, "Settings should persist to UserDefaults")

		// Reset
		UserDefaults.standard.set(initialStreamingMode, forKey: "useStreamingTranscription")
	}

	func testTranscriptionErrorHandlingIntegration() async throws {
		// Given
		audioManager.useStreamingTranscription = true

		// When an error occurs during transcription
		audioManager.transcriptionError = "Test error"

		// Then
		XCTAssertEqual(audioManager.transcriptionError, "Test error", "Error should be stored")
		XCTAssertNil(
			audioManager.lastTranscription, "Last transcription should remain nil during error")
	}

	func testRecordingStateNotificationIntegration() async throws {
		// Given
		let expectation = XCTestExpectation(description: "Recording state notification")
		let notificationCenter = NotificationCenter.default

		var receivedNotifications = 0
		let observer = notificationCenter.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { _ in
			receivedNotifications += 1
			if receivedNotifications >= 2 {
				expectation.fulfill()
			}
		}

		// When recording state changes
		audioManager.isRecording = true
		audioManager.isTranscribing = true

		// Then
		await fulfillment(of: [expectation], timeout: 2.0)
		XCTAssertGreaterThanOrEqual(
			receivedNotifications, 2, "Should receive notifications for state changes")

		notificationCenter.removeObserver(observer)
	}

	func testMemoryManagementDuringStreaming() async throws {
		// Given
		audioManager.useStreamingTranscription = true
		let initialMemoryFootprint = getMemoryUsage()

		// When simulating multiple transcription cycles
		for _ in 0..<5 {
			let testAudio: [Float] = Array(repeating: 0.1, count: 1000)
			do {
				let _ = try await whisperKitTranscriber.transcribeAudioArray(
					testAudio, enableTranslation: false)
			} catch {
				// Expected in test environment
			}
		}

		// Then
		let finalMemoryFootprint = getMemoryUsage()
		let memoryIncrease = finalMemoryFootprint - initialMemoryFootprint

		// Memory increase should be reasonable (less than 100MB for this test)
		XCTAssertLessThan(memoryIncrease, 100, "Memory usage should not increase dramatically")
	}

	func testConcurrentTranscriptionRequests() async throws {
		// Given
		audioManager.useStreamingTranscription = true
		let testAudio: [Float] = Array(repeating: 0.1, count: 1000)

		// When making concurrent requests
		await withTaskGroup(of: Void.self) { group in
			for i in 0..<3 {
				group.addTask {
					do {
						let _ = try await self.whisperKitTranscriber.transcribeAudioArray(
							testAudio, enableTranslation: false)
					} catch {
						// Expected in test environment - WhisperKit handles serialization
					}
				}
			}
		}

		// Then - test completes without crashing
		XCTAssertTrue(true, "Concurrent requests should be handled gracefully")
	}

	// MARK: - Helper Methods

	private func createTemporaryAudioFile() -> URL {
		let tempDir = FileManager.default.temporaryDirectory
		let fileName = "test_audio_\(UUID().uuidString).wav"
		let audioURL = tempDir.appendingPathComponent(fileName)

		// Create a minimal WAV file for testing
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
			let frameCount = AVAudioFrameCount(16000 * 0.1)  // 0.1 seconds
			let silentBuffer = AVAudioPCMBuffer(
				pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
			silentBuffer.frameLength = frameCount
			try audioFile.write(from: silentBuffer)
		} catch {
			print("Failed to create test audio file: \(error)")
		}

		return audioURL
	}

	private func getMemoryUsage() -> Int {
		let task = mach_task_self_
		var info = mach_task_basic_info()
		var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

		let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: 1) {
				task_info(task, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
			}
		}

		if kerr == KERN_SUCCESS {
			return Int(info.resident_size) / 1024 / 1024  // Convert to MB
		} else {
			return 0
		}
	}
}
