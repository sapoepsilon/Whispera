import AppKit
import Foundation
import Observation

struct ModelInfo {
	let name: String
	let displayName: String
	let path: URL
	let size: Int64
	let sizeFormatted: String
	let isDownloaded: Bool
}

enum AppLibraryError: Error, LocalizedError {
	case directoryNotFound
	case accessDenied
	case deletionFailed(String)
	case calculationFailed

	var errorDescription: String? {
		switch self {
		case .directoryNotFound:
			return "App library directory not found"
		case .accessDenied:
			return "Access denied to app library"
		case .deletionFailed(let details):
			return "Failed to delete: \(details)"
		case .calculationFailed:
			return "Failed to calculate storage usage"
		}
	}
}

@Observable
class AppLibraryManager {

	// MARK: - Observable Properties
	var totalStorageUsed: Int64 = 0
	var totalStorageFormatted: String = "0 bytes"
	var downloadedModels: [ModelInfo] = []
	var isCalculatingStorage = false
	var isRemovingModel = false
	var lastError: AppLibraryError?

	// MARK: - Computed Properties

	/// Base application support directory for Whispera
	var appSupportDirectory: URL? {
		guard
			let appSupport = FileManager.default.urls(
				for: .applicationSupportDirectory, in: .userDomainMask
			).first
		else {
			return nil
		}
		return appSupport.appendingPathComponent("Whispera")
	}

	/// WhisperKit models directory
	var modelsDirectory: URL? {
		return appSupportDirectory?.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
	}

	/// Downloads directory where updates are stored
	var downloadsDirectory: URL? {
		return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
	}

	/// Logs directory
	var logsDirectory: URL? {
		return appSupportDirectory?.appendingPathComponent("Logs")
	}

	init() {
		Task {
			await refreshStorageInfo()
		}
	}

	// MARK: - Storage Calculation

	@MainActor
	func refreshStorageInfo() async {
		isCalculatingStorage = true
		defer { isCalculatingStorage = false }

		do {
			let models = try await scanForDownloadedModels()
			downloadedModels = models

			let totalBytes = models.reduce(0) { $0 + $1.size }
			totalStorageUsed = totalBytes
			totalStorageFormatted = ByteCountFormatter.string(
				fromByteCount: totalBytes, countStyle: .file)

			lastError = nil
		} catch {
			lastError = error as? AppLibraryError ?? .calculationFailed
		}
	}

	private func scanForDownloadedModels() async throws -> [ModelInfo] {
		guard let modelsDir = modelsDirectory else {
			throw AppLibraryError.directoryNotFound
		}

		guard FileManager.default.fileExists(atPath: modelsDir.path) else {
			return []
		}

		do {
			let modelFolders = try FileManager.default.contentsOfDirectory(
				at: modelsDir, includingPropertiesForKeys: nil)
			var models: [ModelInfo] = []

			for folder in modelFolders {
				if folder.hasDirectoryPath {
					let modelName = folder.lastPathComponent
					let size = try calculateDirectorySize(at: folder)

					let modelInfo = ModelInfo(
						name: modelName,
						displayName: formatModelDisplayName(modelName),
						path: folder,
						size: size,
						sizeFormatted: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
						isDownloaded: true
					)
					models.append(modelInfo)
				}
			}

			return models.sorted { $0.displayName < $1.displayName }
		} catch {
			throw AppLibraryError.accessDenied
		}
	}

	private func calculateDirectorySize(at url: URL) throws -> Int64 {
		let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
		let enumerator = FileManager.default.enumerator(
			at: url,
			includingPropertiesForKeys: resourceKeys,
			options: [.skipsHiddenFiles]
		)

		var totalSize: Int64 = 0

		while let fileURL = enumerator?.nextObject() as? URL {
			let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

			if resourceValues.isRegularFile == true {
				totalSize += Int64(resourceValues.fileSize ?? 0)
			}
		}

		return totalSize
	}

	private func formatModelDisplayName(_ modelName: String) -> String {
		let cleanName = modelName.replacingOccurrences(of: "openai_whisper-", with: "")

		switch cleanName {
		case "tiny.en": return "Tiny (English)"
		case "tiny": return "Tiny (Multilingual)"
		case "base.en": return "Base (English)"
		case "base": return "Base (Multilingual)"
		case "small.en": return "Small (English)"
		case "small": return "Small (Multilingual)"
		case "medium.en": return "Medium (English)"
		case "medium": return "Medium (Multilingual)"
		case "large-v2": return "Large v2"
		case "large-v3": return "Large v3"
		case "large-v3-turbo": return "Large v3 Turbo"
		case "distil-large-v2": return "Distil Large v2"
		case "distil-large-v3": return "Distil Large v3"
		default: return cleanName.capitalized
		}
	}

	// MARK: - Model Management

	@MainActor
	func removeModel(_ modelInfo: ModelInfo) async throws {
		isRemovingModel = true
		defer { isRemovingModel = false }

		do {
			try FileManager.default.removeItem(at: modelInfo.path)

			// Refresh storage info after removal
			await refreshStorageInfo()

			lastError = nil
		} catch {
			let errorMessage = "Failed to remove \(modelInfo.displayName): \(error.localizedDescription)"
			lastError = .deletionFailed(errorMessage)
			throw lastError!
		}
	}

	@MainActor
	func removeAllModels() async throws {
		guard let modelsDir = modelsDirectory else {
			throw AppLibraryError.directoryNotFound
		}

		isRemovingModel = true
		defer { isRemovingModel = false }

		do {
			if FileManager.default.fileExists(atPath: modelsDir.path) {
				try FileManager.default.removeItem(at: modelsDir)
			}

			// Refresh storage info after removal
			await refreshStorageInfo()

			lastError = nil
		} catch {
			let errorMessage = "Failed to remove all models: \(error.localizedDescription)"
			lastError = .deletionFailed(errorMessage)
			throw lastError!
		}
	}

	// MARK: - File System Operations

	func openAppLibraryInFinder() {
		guard let appSupportDir = appSupportDirectory else {
			showFinderError("Unable to locate app library directory")
			return
		}

		// Create directory if it doesn't exist
		if !FileManager.default.fileExists(atPath: appSupportDir.path) {
			do {
				try FileManager.default.createDirectory(
					at: appSupportDir, withIntermediateDirectories: true)
			} catch {
				showFinderError("Failed to create app library directory: \(error.localizedDescription)")
				return
			}
		}

		let success = NSWorkspace.shared.open(appSupportDir)
		if !success {
			showFinderError("Failed to open app library in Finder")
		}
	}

	func openDownloadsInFinder() {
		guard let downloadsDir = downloadsDirectory else {
			showFinderError("Unable to locate downloads directory")
			return
		}

		// Ensure downloads directory exists
		if !FileManager.default.fileExists(atPath: downloadsDir.path) {
			do {
				try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
			} catch {
				showFinderError("Failed to create downloads directory: \(error.localizedDescription)")
				return
			}
		}

		let success = NSWorkspace.shared.open(downloadsDir)
		if !success {
			showFinderError("Failed to open downloads in Finder")
		}
	}

	func openLogsInFinder() {
		guard let logsDir = logsDirectory else {
			showFinderError("Unable to locate logs directory")
			return
		}

		// Create logs directory if it doesn't exist
		if !FileManager.default.fileExists(atPath: logsDir.path) {
			do {
				try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
			} catch {
				showFinderError("Failed to create logs directory: \(error.localizedDescription)")
				return
			}
		}

		let success = NSWorkspace.shared.open(logsDir)
		if !success {
			showFinderError("Failed to open logs in Finder")
		}
	}

	func revealModelInFinder(_ modelInfo: ModelInfo) {
		NSWorkspace.shared.selectFile(modelInfo.path.path, inFileViewerRootedAtPath: "")
	}

	// MARK: - Update File Management

	func getDownloadedUpdates() -> [URL] {
		guard let downloadsDir = downloadsDirectory else { return [] }

		do {
			let files = try FileManager.default.contentsOfDirectory(
				at: downloadsDir, includingPropertiesForKeys: nil)
			return files.filter {
				$0.pathExtension == "dmg" && $0.lastPathComponent.hasPrefix("Whispera-")
			}
		} catch {
			return []
		}
	}

	func removeDownloadedUpdate(at url: URL) throws {
		try FileManager.default.removeItem(at: url)
	}

	func getUpdateFileSize(at url: URL) -> Int64 {
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			return attributes[.size] as? Int64 ?? 0
		} catch {
			return 0
		}
	}

	// MARK: - Storage Utilities

	func formatBytes(_ bytes: Int64) -> String {
		return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}

	// MARK: - Log Management

	func getLogsSize() async -> (size: Int64, formatted: String) {
		let size = LogManager.shared.calculateLogsSize()
		let formatted = formatBytes(size)
		return (size, formatted)
	}

	func clearLogs() async throws {
		try LogManager.shared.clearAllLogs()
	}

	var hasModels: Bool {
		return !downloadedModels.isEmpty
	}

	var modelsCount: Int {
		return downloadedModels.count
	}

	// MARK: - Error Handling

	private func showFinderError(_ message: String) {
		DispatchQueue.main.async {
			let alert = NSAlert()
			alert.messageText = "Finder Error"
			alert.informativeText = message
			alert.alertStyle = .warning
			alert.addButton(withTitle: "OK")
			alert.runModal()
		}
	}
}

// MARK: - Storage Summary Extension

extension AppLibraryManager {

	/// Gets a summary of storage usage for display
	func getStorageSummary() -> String {
		if downloadedModels.isEmpty {
			return "No models downloaded"
		}

		let modelWord = downloadedModels.count == 1 ? "model" : "models"
		return "\(downloadedModels.count) \(modelWord) • \(totalStorageFormatted)"
	}

	/// Gets detailed breakdown of storage usage
	func getDetailedStorageInfo() -> [String] {
		var info: [String] = []

		if !downloadedModels.isEmpty {
			info.append("Downloaded Models:")
			for model in downloadedModels {
				info.append("  • \(model.displayName): \(model.sizeFormatted)")
			}
			info.append("")
			info.append("Total: \(totalStorageFormatted)")
		}

		let updates = getDownloadedUpdates()
		if !updates.isEmpty {
			info.append("")
			info.append("Downloaded Updates:")
			for update in updates {
				let size = getUpdateFileSize(at: update)
				let sizeFormatted = formatBytes(size)
				info.append("  • \(update.lastPathComponent): \(sizeFormatted)")
			}
		}

		return info
	}
}
