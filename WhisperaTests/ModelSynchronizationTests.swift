import XCTest

@testable import Whispera

@MainActor
final class ModelSynchronizationTests: XCTestCase {

	override func setUp() async throws {
		// Reset UserDefaults for clean test state
		UserDefaults.standard.removeObject(forKey: "selectedModel")
		UserDefaults.standard.removeObject(forKey: "lastUsedModel")
	}

	func testSelectedModelInAppStorageMatchesWhisperKitCurrentModel() async throws {
		// This test verifies that @AppStorage("selectedModel") stays in sync with WhisperKit's currentModel

		// Given
		let transcriber = WhisperKitTranscriber.shared
		let testModel = "openai_whisper-base.en"

		// When WhisperKit loads a model
		transcriber.currentModel = testModel
		transcriber.lastUsedModel = testModel

		// Then selectedModel in UserDefaults should be updated
		let selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
		XCTAssertEqual(
			selectedModel, testModel,
			"@AppStorage(selectedModel) should automatically sync with WhisperKit's currentModel")
	}

	func testSettingsViewSelectedModelProperty() async throws {
		// This tests that SettingsView's selectedModel property correctly reflects the loaded model

		// Given
		let testModel = "openai_whisper-small"
		UserDefaults.standard.set(testModel, forKey: "selectedModel")

		// When creating SettingsView (simulated)
		let selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? ""

		// Then it should match what we set
		XCTAssertEqual(selectedModel, testModel)

		// When WhisperKit loads a different model
		let transcriber = WhisperKitTranscriber.shared
		let newModel = "openai_whisper-base"
		transcriber.currentModel = newModel

		// Then selectedModel should update (this will fail until we fix the sync)
		// In the actual fix, we need to ensure this happens
		XCTAssertEqual(
			UserDefaults.standard.string(forKey: "selectedModel"), newModel,
			"selectedModel should update when WhisperKit loads a different model")
	}

	func testIsCurrentModelLoadedLogic() async throws {
		// Test the logic that determines if the current model is loaded

		// Given
		let transcriber = WhisperKitTranscriber.shared
		let testModel = "openai_whisper-base"

		// Scenario 1: No model loaded
		transcriber.currentModel = nil
		UserDefaults.standard.set(testModel, forKey: "selectedModel")

		XCTAssertFalse(
			transcriber.isCurrentModelLoaded(),
			"Should return false when no model is loaded")

		// Scenario 2: Same model loaded
		transcriber.currentModel = testModel
		UserDefaults.standard.set(testModel, forKey: "selectedModel")

		XCTAssertTrue(
			transcriber.isCurrentModelLoaded(),
			"Should return true when selected model matches loaded model")

		// Scenario 3: Different model selected
		UserDefaults.standard.set("openai_whisper-small", forKey: "selectedModel")

		XCTAssertFalse(
			transcriber.isCurrentModelLoaded(),
			"Should return false when selected model differs from loaded model")
	}

	func testModelLoadingUpdatesSelectedModel() async throws {
		// Test that loading a model updates the selectedModel

		// Given
		let transcriber = WhisperKitTranscriber.shared
		UserDefaults.standard.set("openai_whisper-tiny", forKey: "selectedModel")

		// When loading a different model
		let newModel = "openai_whisper-base"
		// Simulate the loadModel function behavior
		transcriber.currentModel = newModel
		transcriber.lastUsedModel = newModel

		// Then selectedModel should be updated to match
		// This is what needs to be fixed - selectedModel should sync with currentModel
		XCTAssertEqual(
			UserDefaults.standard.string(forKey: "selectedModel"), newModel,
			"selectedModel should be updated when a model is loaded")
	}
}
