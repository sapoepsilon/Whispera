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
        
        // Then
        // After initialization, the last used model should be loaded
        let transcriber = WhisperKitTranscriber.shared
        
        // Wait for initialization
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        XCTAssertEqual(transcriber.currentModel, testModel, "Should auto-load the last used model")
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