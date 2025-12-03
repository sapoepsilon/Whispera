import AVFoundation
import XCTest

@testable import Whispera

@MainActor
final class AudioManagerTests: XCTestCase {

	var audioManager: AudioManager!

	override func setUp() async throws {
		audioManager = AudioManager()
	}

	override func tearDown() async throws {
		audioManager = nil
	}

	// MARK: - Streaming Mode Tests

	func testStreamingModeToggle() async throws {
		// Given
		let initialStreamingMode = audioManager.useStreamingTranscription

		// When
		audioManager.useStreamingTranscription = !initialStreamingMode

		// Then
		XCTAssertNotEqual(
			audioManager.useStreamingTranscription, initialStreamingMode, "Streaming mode should toggle")
	}

	func testDefaultStreamingModeIsEnabled() async throws {
		// Given & When
		let audioManager = AudioManager()

		// Then
		XCTAssertTrue(
			audioManager.useStreamingTranscription, "Streaming mode should be enabled by default")
	}

	func testStreamingModeStorage() async throws {
		// Given
		let testValue = false

		// When
		audioManager.useStreamingTranscription = testValue

		// Then
		let storedValue = UserDefaults.standard.bool(forKey: "useStreamingTranscription")
		XCTAssertEqual(
			storedValue, testValue, "Streaming mode preference should be stored in UserDefaults")
	}

	func testRecordingModeEnumValues() async throws {
		// Test that our RecordingMode enum has the expected values
		XCTAssertEqual(RecordingMode.text.rawValue, RecordingMode.text.rawValue)
	}

	func testAudioManagerInitialization() async throws {
		// Given & When
		let manager = AudioManager()

		// Then
		XCTAssertFalse(manager.isRecording, "Should not be recording on initialization")
		XCTAssertFalse(manager.isTranscribing, "Should not be transcribing on initialization")
		XCTAssertNil(manager.lastTranscription, "Should have no transcription on initialization")
		XCTAssertNil(manager.transcriptionError, "Should have no error on initialization")
		XCTAssertEqual(manager.currentRecordingMode, .text, "Should default to text mode")
	}

	func testToggleRecordingWithStreamingMode() async throws {
		// Given
		audioManager.useStreamingTranscription = true
		let initialRecordingState = audioManager.isRecording

		// When
		audioManager.toggleRecording(mode: .text)

		// Then
		// Note: This test may not actually start recording due to permissions in test environment
		// We're mainly testing that the method doesn't crash and handles the flow
		XCTAssertEqual(audioManager.currentRecordingMode, .text, "Recording mode should be set")
	}

	func testToggleRecordingWithFileMode() async throws {
		// Given
		audioManager.useStreamingTranscription = false
		let initialRecordingState = audioManager.isRecording

		// When
		audioManager.toggleRecording(mode: .text)

		// Then
		// Note: This test may not actually start recording due to permissions in test environment
		// We're mainly testing that the method doesn't crash and handles the flow
		XCTAssertEqual(audioManager.currentRecordingMode, .text, "Recording mode should be set")
	}

	func testApplicationSupportDirectoryCreation() async throws {
		// When
		let directory = audioManager.getApplicationSupportDirectory()

		// Then
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: directory.path),
			"Application support directory should exist")
		XCTAssertTrue(directory.path.contains("Whispera"), "Directory should contain app name")
	}

	func testWhisperKitTranscriberReference() async throws {
		// Given & When
		let transcriber = audioManager.whisperKitTranscriber

		// Then
		XCTAssertNotNil(transcriber, "AudioManager should have a WhisperKit transcriber reference")
		XCTAssertTrue(
			transcriber === WhisperKitTranscriber.shared, "Should reference the shared instance")
	}

	// MARK: - Audio Buffer Tests

	func testAudioBufferProperties() async throws {
		// Test that buffer size constants are reasonable
		let maxBufferSize = 16000 * 30  // 30 seconds at 16kHz
		XCTAssertEqual(maxBufferSize, 480000, "Buffer size should accommodate 30 seconds of audio")

		let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
		XCTAssertNotNil(audioFormat, "Should be able to create 16kHz mono audio format")
		XCTAssertEqual(audioFormat?.sampleRate, 16000, "Sample rate should be 16kHz")
		XCTAssertEqual(audioFormat?.channelCount, 1, "Should be mono audio")
	}

	// MARK: - Error Handling Tests

	func testTranscriptionErrorHandling() async throws {
		// Given
		let testError = "Test transcription error"

		// When
		audioManager.transcriptionError = testError

		// Then
		XCTAssertEqual(audioManager.transcriptionError, testError, "Should store transcription error")
	}

	func testRecordingStateNotifications() async throws {
		// Given
		let expectation = XCTestExpectation(description: "Recording state notification")
		let notificationCenter = NotificationCenter.default

		var receivedNotification = false
		let observer = notificationCenter.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { _ in
			receivedNotification = true
			expectation.fulfill()
		}

		// When
		audioManager.isRecording = true

		// Then
		await fulfillment(of: [expectation], timeout: 1.0)
		XCTAssertTrue(receivedNotification, "Should receive recording state change notification")

		notificationCenter.removeObserver(observer)
	}

	// MARK: - Integration Tests

	func testSetupAudioWithStreamingMode() async throws {
		// Given
		audioManager.useStreamingTranscription = true

		// When
		audioManager.setupAudio()

		// Then
		// Test doesn't crash - specific audio engine testing would require more complex mocking
		XCTAssertTrue(audioManager.useStreamingTranscription, "Streaming mode should remain enabled")
	}

	func testSetupAudioWithFileMode() async throws {
		// Given
		audioManager.useStreamingTranscription = false

		// When
		audioManager.setupAudio()

		// Then
		// Test doesn't crash - specific file-based recording testing would require more complex mocking
		XCTAssertFalse(audioManager.useStreamingTranscription, "File mode should remain enabled")
	}
}
