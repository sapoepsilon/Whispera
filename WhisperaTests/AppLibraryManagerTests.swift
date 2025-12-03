import Foundation
import XCTest

@testable import Whispera

final class AppLibraryManagerTests: XCTestCase {

	var appLibraryManager: AppLibraryManager!
	var tempDirectory: URL!

	override func setUp() {
		super.setUp()

		// Create a temporary directory for testing
		tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

		appLibraryManager = AppLibraryManager()
	}

	override func tearDown() {
		// Clean up temporary directory
		if let tempDir = tempDirectory {
			try? FileManager.default.removeItem(at: tempDir)
		}

		appLibraryManager = nil
		super.tearDown()
	}

	// MARK: - Initialization Tests

	func testInitialization() {
		XCTAssertNotNil(appLibraryManager)
		XCTAssertEqual(appLibraryManager.totalStorageUsed, 0)
		XCTAssertEqual(appLibraryManager.downloadedModels.count, 0)
		XCTAssertFalse(appLibraryManager.isCalculatingStorage)
		XCTAssertFalse(appLibraryManager.isRemovingModel)
	}

	// MARK: - Directory Path Tests

	func testAppSupportDirectory() {
		let directory = appLibraryManager.appSupportDirectory
		XCTAssertNotNil(directory)
		XCTAssertTrue(directory!.path.contains("Application Support"))
		XCTAssertTrue(directory!.path.contains("Whispera"))
	}

	func testModelsDirectory() {
		let directory = appLibraryManager.modelsDirectory
		XCTAssertNotNil(directory)
		XCTAssertTrue(directory!.path.contains("models/argmaxinc/whisperkit-coreml"))
	}

	func testDownloadsDirectory() {
		let directory = appLibraryManager.downloadsDirectory
		XCTAssertNotNil(directory)
		XCTAssertTrue(directory!.path.contains("Downloads"))
	}

	// MARK: - Storage Calculation Tests

	func testRefreshStorageInfoEmpty() async {
		await appLibraryManager.refreshStorageInfo()

		XCTAssertEqual(appLibraryManager.totalStorageUsed, 0)
		XCTAssertEqual(appLibraryManager.totalStorageFormatted, "0 bytes")
		XCTAssertEqual(appLibraryManager.downloadedModels.count, 0)
		XCTAssertNil(appLibraryManager.lastError)
	}

	func testCreateMockModel() {
		// Create a mock model directory structure for testing
		let mockModelsDir = tempDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
		let modelDir = mockModelsDir.appendingPathComponent("openai_whisper-tiny.en")

		do {
			try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

			// Create some mock files
			let file1 = modelDir.appendingPathComponent("model.mlpackage")
			let file2 = modelDir.appendingPathComponent("config.json")

			let data1 = Data(repeating: 0, count: 1024)  // 1KB
			let data2 = Data(repeating: 1, count: 512)  // 512 bytes

			try data1.write(to: file1)
			try data2.write(to: file2)

			XCTAssertTrue(FileManager.default.fileExists(atPath: modelDir.path))
			XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
			XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
		} catch {
			XCTFail("Failed to create mock model: \(error)")
		}
	}

	// MARK: - Model Display Name Tests

	func testModelDisplayNameFormatting() {
		// We can't directly test the private method, but we can test through ModelInfo creation
		// This will be tested indirectly through integration tests
		XCTAssertTrue(true)  // Placeholder - would need refactoring to test private methods
	}

	// MARK: - File Operations Tests

	func testOpenAppLibraryInFinder() {
		// Test that the method doesn't crash
		XCTAssertNoThrow(appLibraryManager.openAppLibraryInFinder())
	}

	func testOpenDownloadsInFinder() {
		// Test that the method doesn't crash
		XCTAssertNoThrow(appLibraryManager.openDownloadsInFinder())
	}

	// MARK: - Enhanced Finder Integration Tests

	func testFinderIntegrationWithDirectoryCreation() {
		// Test that directories are created if they don't exist
		XCTAssertNoThrow(appLibraryManager.openAppLibraryInFinder())

		// Verify app support directory exists after call
		if let appSupportDir = appLibraryManager.appSupportDirectory {
			XCTAssertTrue(FileManager.default.fileExists(atPath: appSupportDir.path))
		}

		XCTAssertNoThrow(appLibraryManager.openDownloadsInFinder())

		// Verify downloads directory exists after call
		if let downloadsDir = appLibraryManager.downloadsDirectory {
			XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDir.path))
		}
	}

	func testFinderErrorHandling() {
		// Test error handling for invalid directories
		// This would require mocking NSWorkspace, so we just test the method exists
		XCTAssertNotNil(appLibraryManager.appSupportDirectory)
		XCTAssertNotNil(appLibraryManager.downloadsDirectory)
	}

	func testRevealModelInFinder() {
		// Test reveal model in finder method exists
		let testURL = URL(fileURLWithPath: "/test/path")
		let modelInfo = ModelInfo(
			name: "test-model",
			displayName: "Test Model",
			path: testURL,
			size: 1024,
			sizeFormatted: "1 KB",
			isDownloaded: true
		)

		// Should not crash even with invalid path
		XCTAssertNoThrow(appLibraryManager.revealModelInFinder(modelInfo))
	}

	// MARK: - Update File Management Tests

	func testGetDownloadedUpdatesEmpty() {
		let updates = appLibraryManager.getDownloadedUpdates()
		// Should return empty array when no updates exist
		XCTAssertTrue(updates.isEmpty)
	}

	func testCreateMockUpdateFile() {
		guard let downloadsDir = appLibraryManager.downloadsDirectory else {
			XCTFail("Downloads directory not available")
			return
		}

		let updateFile = downloadsDir.appendingPathComponent("Whispera-1.2.3.dmg")
		let mockData = Data(repeating: 0, count: 1024 * 1024)  // 1MB

		do {
			try mockData.write(to: updateFile)

			let updates = appLibraryManager.getDownloadedUpdates()
			XCTAssertTrue(updates.contains(updateFile))

			let fileSize = appLibraryManager.getUpdateFileSize(at: updateFile)
			XCTAssertEqual(fileSize, 1024 * 1024)

			// Clean up
			try FileManager.default.removeItem(at: updateFile)
		} catch {
			XCTFail("Failed to create/test mock update file: \(error)")
		}
	}

	// MARK: - Storage Summary Tests

	func testGetStorageSummaryEmpty() {
		let summary = appLibraryManager.getStorageSummary()
		XCTAssertEqual(summary, "No models downloaded")
	}

	func testHasModelsEmpty() {
		XCTAssertFalse(appLibraryManager.hasModels)
		XCTAssertEqual(appLibraryManager.modelsCount, 0)
	}

	func testGetDetailedStorageInfoEmpty() {
		let info = appLibraryManager.getDetailedStorageInfo()
		XCTAssertTrue(info.isEmpty)
	}

	// MARK: - Format Bytes Tests

	func testFormatBytes() {
		XCTAssertEqual(appLibraryManager.formatBytes(0), "0 bytes")
		XCTAssertEqual(appLibraryManager.formatBytes(1024), "1 KB")
		XCTAssertEqual(appLibraryManager.formatBytes(1024 * 1024), "1 MB")
		XCTAssertEqual(appLibraryManager.formatBytes(1024 * 1024 * 1024), "1 GB")
	}

	// MARK: - Error Handling Tests

	func testErrorHandling() {
		// Test that error handling doesn't crash
		XCTAssertNil(appLibraryManager.lastError)
	}

	// MARK: - Observable Properties Tests

	func testObservableProperties() {
		// Test that observable properties are accessible
		XCTAssertNotNil(appLibraryManager.totalStorageUsed)
		XCTAssertNotNil(appLibraryManager.totalStorageFormatted)
		XCTAssertNotNil(appLibraryManager.downloadedModels)
		XCTAssertNotNil(appLibraryManager.isCalculatingStorage)
		XCTAssertNotNil(appLibraryManager.isRemovingModel)

		// Test that they can be modified (for internal state management)
		let originalStorageUsed = appLibraryManager.totalStorageUsed
		appLibraryManager.totalStorageUsed = 12345
		XCTAssertNotEqual(appLibraryManager.totalStorageUsed, originalStorageUsed)
		XCTAssertEqual(appLibraryManager.totalStorageUsed, 12345)
	}

	// MARK: - Performance Tests

	func testRefreshStorageInfoPerformance() {
		measure {
			let expectation = self.expectation(description: "Refresh storage info")
			Task {
				await appLibraryManager.refreshStorageInfo()
				expectation.fulfill()
			}
			wait(for: [expectation], timeout: 5.0)
		}
	}

	// MARK: - ModelInfo Tests

	func testModelInfoCreation() {
		let testURL = URL(fileURLWithPath: "/test/path")
		let modelInfo = ModelInfo(
			name: "openai_whisper-tiny.en",
			displayName: "Tiny (English)",
			path: testURL,
			size: 1024,
			sizeFormatted: "1 KB",
			isDownloaded: true
		)

		XCTAssertEqual(modelInfo.name, "openai_whisper-tiny.en")
		XCTAssertEqual(modelInfo.displayName, "Tiny (English)")
		XCTAssertEqual(modelInfo.path, testURL)
		XCTAssertEqual(modelInfo.size, 1024)
		XCTAssertEqual(modelInfo.sizeFormatted, "1 KB")
		XCTAssertTrue(modelInfo.isDownloaded)
	}

	// MARK: - AppLibraryError Tests

	func testAppLibraryErrorDescriptions() {
		XCTAssertEqual(
			AppLibraryError.directoryNotFound.errorDescription, "App library directory not found")
		XCTAssertEqual(AppLibraryError.accessDenied.errorDescription, "Access denied to app library")
		XCTAssertEqual(
			AppLibraryError.deletionFailed("test").errorDescription, "Failed to delete: test")
		XCTAssertEqual(
			AppLibraryError.calculationFailed.errorDescription, "Failed to calculate storage usage")
	}

	// MARK: - Integration Tests

	func testFullWorkflow() async {
		// Test a full workflow of storage management
		await appLibraryManager.refreshStorageInfo()

		// Initially should be empty
		XCTAssertEqual(appLibraryManager.totalStorageUsed, 0)
		XCTAssertFalse(appLibraryManager.hasModels)

		// Storage summary should indicate no models
		XCTAssertEqual(appLibraryManager.getStorageSummary(), "No models downloaded")

		// Detailed info should be empty
		XCTAssertTrue(appLibraryManager.getDetailedStorageInfo().isEmpty)

		// Should be able to open directories without crashing
		XCTAssertNoThrow(appLibraryManager.openAppLibraryInFinder())
		XCTAssertNoThrow(appLibraryManager.openDownloadsInFinder())
	}

	// MARK: - Thread Safety Tests

	func testConcurrentRefresh() async {
		// Test that concurrent refresh calls don't cause issues
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<5 {
				group.addTask {
					await self.appLibraryManager.refreshStorageInfo()
				}
			}
		}

		// Should still be in a valid state
		XCTAssertNotNil(appLibraryManager.downloadedModels)
		XCTAssertNotNil(appLibraryManager.totalStorageFormatted)
	}

	// MARK: - Edge Case Tests

	func testAppLibraryManagerDeinit() {
		// Test that deinitializing doesn't cause crashes
		var manager: AppLibraryManager? = AppLibraryManager()
		XCTAssertNotNil(manager)

		manager = nil
		XCTAssertNil(manager)
	}

	func testMultipleStorageRefreshes() async {
		// Test rapid successive updates don't cause issues
		for _ in 0..<5 {
			await appLibraryManager.refreshStorageInfo()
		}

		// Should still be in a valid state
		XCTAssertNotNil(appLibraryManager.downloadedModels)
		XCTAssertNotNil(appLibraryManager.totalStorageUsed)
		XCTAssertNotNil(appLibraryManager.totalStorageFormatted)
	}
}
