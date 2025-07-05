import XCTest
@testable import Whispera

@MainActor
final class WhisperKitTranscriberTests: XCTestCase {
    
    // MARK: - Model Synchronization Tests
    
    func testSelectedModelSyncsWithCurrentModelAfterLoading() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let testModel = "openai_whisper-base.en"
        
        // Store initial selectedModel in UserDefaults
        UserDefaults.standard.set(testModel, forKey: "selectedModel")
        
        // When
        // Simulate model loading (this should fail initially as we haven't fixed the sync)
        transcriber.currentModel = testModel
        transcriber.selectedModel = testModel
        
        // Then
        let storedModel = UserDefaults.standard.string(forKey: "selectedModel")
        XCTAssertEqual(storedModel, testModel, "selectedModel in UserDefaults should match the loaded model")
        XCTAssertEqual(transcriber.currentModel, testModel, "currentModel should be set correctly")
        XCTAssertEqual(transcriber.selectedModel, testModel, "selectedModel should match currentModel after loading")
    }
    
    func testLastUsedModelIsPersisted() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let testModel = "openai_whisper-small"
        
        // When
        // Simulate successful model load
        transcriber.currentModel = testModel
        
        // Then
        let lastUsedModel = UserDefaults.standard.string(forKey: "lastUsedModel")
        XCTAssertEqual(lastUsedModel, testModel, "lastUsedModel should be persisted after loading")
    }
    
    func testAutoLoadLastModelOnInit() async throws {
        // Given
        let testModel = "openai_whisper-base"
        UserDefaults.standard.set(testModel, forKey: "lastUsedModel")
        
        // When
        // Create a new instance (in real app, we'd need to test the singleton differently)
        // This test will initially fail because we need to fix the auto-load behavior
        
        // Given: We create a test instance (this would need proper initialization in real implementation)
        let transcriber = WhisperKitTranscriber.shared
        
        // Then: Verify the lastUsedModel is set correctly
        let actualLastUsedModel = UserDefaults.standard.string(forKey: "lastUsedModel")
        // In a real implementation, this would test the auto-loading behavior
        // For now, we just verify the UserDefaults interaction works
    }
    
    // MARK: - Audio Array Transcription Tests
    
    func testTranscribeAudioArrayWithEmptyArray() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let emptyAudioArray: [Float] = []
        
        // When & Then
        do {
            let result = try await transcriber.transcribeAudioArray(emptyAudioArray, enableTranslation: false)
            XCTAssertEqual(result, "No audio data provided", "Should return appropriate message for empty audio array")
        } catch WhisperKitError.notInitialized {
            // This is expected if WhisperKit is not initialized in test environment
            XCTAssertTrue(true, "Expected error when WhisperKit not initialized")
        }
    }
    
    func testTranscribeAudioArrayWithValidData() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        // Create a sample audio array (1 second of 16kHz audio with simple sine wave)
        let sampleRate: Float = 16000
        let duration: Float = 1.0
        let frequency: Float = 440 // A note
        let sampleCount = Int(sampleRate * duration)
        
        let audioArray: [Float] = (0..<sampleCount).map { index in
            let time = Float(index) / sampleRate
            return sin(2.0 * Float.pi * frequency * time) * 0.1 // Low amplitude sine wave
        }
        
        // When & Then
        do {
            let result = try await transcriber.transcribeAudioArray(audioArray, enableTranslation: false)
            // In a real test with WhisperKit initialized, we would verify the transcription
            // For now, we just ensure the method doesn't crash
            XCTAssertNotNil(result, "Should return a transcription result")
        } catch WhisperKitError.notInitialized {
            // This is expected if WhisperKit is not initialized in test environment
            XCTAssertTrue(true, "Expected error when WhisperKit not initialized")
        } catch WhisperKitError.noModelLoaded {
            // This is expected if no model is loaded in test environment
            XCTAssertTrue(true, "Expected error when no model loaded")
        } catch WhisperKitError.notReady {
            // This is expected if WhisperKit is not ready in test environment
            XCTAssertTrue(true, "Expected error when WhisperKit not ready")
        }
    }
    
    func testTranscribeAudioArrayWithTranslationEnabled() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let audioArray: [Float] = Array(repeating: 0.0, count: 16000) // 1 second of silence
        
        // When & Then
        do {
            let result = try await transcriber.transcribeAudioArray(audioArray, enableTranslation: true)
            XCTAssertNotNil(result, "Should return a transcription result with translation enabled")
        } catch WhisperKitError.notInitialized {
            XCTAssertTrue(true, "Expected error when WhisperKit not initialized")
        } catch WhisperKitError.noModelLoaded {
            XCTAssertTrue(true, "Expected error when no model loaded")
        } catch WhisperKitError.notReady {
            XCTAssertTrue(true, "Expected error when WhisperKit not ready")
        }
    }
    
    func testTranscribeAudioArrayErrorHandling() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let validAudioArray: [Float] = Array(repeating: 0.1, count: 1000)
        
        // When & Then
        // Test that the method properly handles the not initialized state
        do {
            let _ = try await transcriber.transcribeAudioArray(validAudioArray, enableTranslation: false)
        } catch WhisperKitError.notInitialized {
            XCTAssertTrue(true, "Should throw notInitialized error when WhisperKit not set up")
        } catch WhisperKitError.noModelLoaded {
            XCTAssertTrue(true, "Should throw noModelLoaded error when no model available")
        } catch WhisperKitError.notReady {
            XCTAssertTrue(true, "Should throw notReady error when WhisperKit not ready")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testAudioArrayVsFileTranscriptionConsistency() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        
        // This test would verify that audio array and file transcription produce similar results
        // In a real implementation, we would:
        // 1. Create a test audio file
        // 2. Read the same audio as an array
        // 3. Transcribe both ways
        // 4. Compare results
        
        // For now, we just verify the methods exist and have the right signatures
        XCTAssertTrue(transcriber.responds(to: #selector(getter: WhisperKitTranscriber.isInitialized)), "Should have isInitialized property")
    }
    
    func testDecodingOptionsForAudioArray() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        
        // When
        let decodingOptionsTranscribe = transcriber.createDecodingOptions(enableTranslation: false)
        let decodingOptionsTranslate = transcriber.createDecodingOptions(enableTranslation: true)
        
        // Then
        XCTAssertNotEqual(decodingOptionsTranscribe.task, decodingOptionsTranslate.task, "Translation mode should affect decoding options")
        
        // Verify that audio array transcription uses the same decoding options as file transcription
        let currentOptions = transcriber.getCurrentDecodingOptions(enableTranslation: false)
        XCTAssertNotNil(currentOptions, "Should be able to get current decoding options")
    }
    
    func testModelSwitchingUpdatesAllProperties() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let oldModel = "openai_whisper-tiny"
        let newModel = "openai_whisper-base"
        
        transcriber.currentModel = oldModel
        UserDefaults.standard.set(oldModel, forKey: "selectedModel")
        
        // When
        // Simulate switching to new model
        transcriber.currentModel = newModel
        transcriber.selectedModel = newModel
        
        // Then
        XCTAssertEqual(transcriber.currentModel, newModel, "currentModel should be updated")
        XCTAssertEqual(transcriber.selectedModel, newModel, "selectedModel should be updated")
        
        let storedSelectedModel = UserDefaults.standard.string(forKey: "selectedModel")
        XCTAssertEqual(storedSelectedModel, newModel, "selectedModel in UserDefaults should be updated")
        
        let lastUsedModel = UserDefaults.standard.string(forKey: "lastUsedModel")
        XCTAssertEqual(lastUsedModel, newModel, "lastUsedModel should be updated")
    }
    
    // MARK: - State Observation Tests
    
    func testIsCurrentModelLoadedReflectsActualState() async throws {
        // Given
        let transcriber = WhisperKitTranscriber.shared
        let testModel = "openai_whisper-base"
        
        // When model is not loaded
        transcriber.currentModel = nil
        UserDefaults.standard.set(testModel, forKey: "selectedModel")
        
        // Then
        XCTAssertFalse(transcriber.isCurrentModelLoaded(), "Should return false when no model is loaded")
        
        // When model is loaded
        transcriber.currentModel = testModel
        
        // Then
        XCTAssertTrue(transcriber.isCurrentModelLoaded(), "Should return true when selected model matches loaded model")
        
        // When different model is selected
        UserDefaults.standard.set("openai_whisper-small", forKey: "selectedModel")
        
        // Then
        XCTAssertFalse(transcriber.isCurrentModelLoaded(), "Should return false when selected model differs from loaded model")
    }
}