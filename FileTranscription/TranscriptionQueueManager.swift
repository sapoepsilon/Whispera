import Foundation
import SwiftUI

// MARK: - Queue Item Data Model
@Observable
class TranscriptionQueueItem: Identifiable {
	let id = UUID()
	let url: URL
	let filename: String
	var displayName: String
	var status: QueueItemStatus = QueueItemStatus.pending
	var progress: Double = 0.0
	var result: String?
	var error: String?
	var filePath: String?

	init(url: URL, displayName: String? = nil) {
		self.url = url
		self.filename = url.lastPathComponent
		self.displayName = displayName ?? url.lastPathComponent
	}
}

enum QueueItemStatus {
	case pending
	case processing
	case completed
	case failed
	case cancelled

	var displayName: String {
		switch self {
		case .pending: return "Pending"
		case .processing: return "Processing"
		case .completed: return "Completed"
		case .failed: return "Failed"
		case .cancelled: return "Cancelled"
		}
	}

	var color: Color {
		switch self {
		case .pending: return .secondary
		case .processing: return .blue
		case .completed: return .green
		case .failed: return .red
		case .cancelled: return .orange
		}
	}

	var icon: String {
		switch self {
		case .pending: return "clock"
		case .processing: return "waveform"
		case .completed: return "checkmark.circle.fill"
		case .failed: return "xmark.circle.fill"
		case .cancelled: return "minus.circle.fill"
		}
	}
}

// MARK: - Transcription Queue Manager

@MainActor
@Observable
class TranscriptionQueueManager {

	// MARK: - Published Properties
	var items: [TranscriptionQueueItem] = []
	var isProcessing: Bool = false
	var currentItem: TranscriptionQueueItem?
	var isExpanded: Bool = false

	// MARK: - Private Properties
	private let fileTranscriptionManager: FileTranscriptionManager
	private let networkDownloader: NetworkFileDownloader
	private let logger = AppLogger.shared.fileTranscriber
	private var processingTask: Task<Void, Never>?

	// MARK: - Computed Properties
	var pendingItems: [TranscriptionQueueItem] {
		items.filter { item in item.status == QueueItemStatus.pending }
	}

	var processingItems: [TranscriptionQueueItem] {
		items.filter { item in item.status == QueueItemStatus.processing }
	}

	var completedItems: [TranscriptionQueueItem] {
		items.filter { item in item.status == QueueItemStatus.completed }
	}

	var failedItems: [TranscriptionQueueItem] {
		items.filter { item in item.status == QueueItemStatus.failed }
	}

	var hasItems: Bool {
		!items.isEmpty
	}

	var overallProgress: Double {
		guard !items.isEmpty else { return 0.0 }
		let completedCount = completedItems.count
		let totalCount = items.count
		let currentProgress = currentItem?.progress ?? 0.0
		return (Double(completedCount) + currentProgress) / Double(totalCount)
	}

	init(fileTranscriptionManager: FileTranscriptionManager, networkDownloader: NetworkFileDownloader) {
		self.fileTranscriptionManager = fileTranscriptionManager
		self.networkDownloader = networkDownloader
	}

	// MARK: - Helper Methods

	private func isYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
			|| host == "m.youtube.com"
	}

	// MARK: - Queue Management
	func addFiles(_ urls: [URL]) {
		logger.info("📋 Adding \(urls.count) files to transcription queue")
		let newItems = urls.map { TranscriptionQueueItem(url: $0) }
		items.append(contentsOf: newItems)
		if !isProcessing {
			startProcessing()
		}
	}

	func addFiles(_ urls: [URL], displayNames: [String]) {
		logger.info("📋 Adding \(urls.count) files to transcription queue with custom names")
		let newItems = zip(urls, displayNames).map { url, displayName in
			TranscriptionQueueItem(url: url, displayName: displayName)
		}
		items.append(contentsOf: newItems)
		if !isProcessing {
			startProcessing()
		}
	}

	func addFile(_ url: URL) {
		addFiles([url])
	}

	func removeItem(_ item: TranscriptionQueueItem) {
		logger.info("🗑️ Removing item from queue: \(item.displayName)")
		if item.status == .processing {
			fileTranscriptionManager.cancelTranscription()
			currentItem = nil
		}
		items.removeAll { $0.id == item.id }
		if items.isEmpty {
			stopProcessing()
		}
	}

	func cancelItem(_ item: TranscriptionQueueItem) {
		logger.info("🛑 Cancelling transcription for: \(item.displayName)")

		if item.status == QueueItemStatus.processing {
			fileTranscriptionManager.cancelTranscription()
			currentItem = nil
		}

		items.removeAll { $0.id == item.id }
		if items.isEmpty {
			stopProcessing()
		}
	}

	func cancelAll() {
		logger.info("🛑 Cancelling all transcriptions in queue")

		// Cancel current processing
		if isProcessing {
			fileTranscriptionManager.cancelTranscription()
		}

		// Remove all non-completed items
		items.removeAll { item in
			item.status == QueueItemStatus.pending || item.status == QueueItemStatus.processing
		}

		stopProcessing()
	}

	func clearCompleted() {
		logger.info("🧹 Clearing completed items from queue")
		items.removeAll { item in item.status == QueueItemStatus.completed }
	}

	func clearAll() {
		logger.info("🧹 Clearing all items from queue")
		cancelAll()
		items.removeAll()
		isExpanded = false
	}

	func retryFailed() {
		logger.info("🔄 Retrying failed transcriptions")

		for item in failedItems {
			item.status = QueueItemStatus.pending
			item.progress = 0.0
			item.error = nil
			item.result = nil
		}

		if !isProcessing {
			startProcessing()
		}
	}

	// MARK: - Processing

	private func startProcessing() {
		guard !isProcessing, !pendingItems.isEmpty else { return }

		logger.info("▶️ Starting queue processing")
		isProcessing = true

		// Notify UI of processing state change
		NotificationCenter.default.post(
			name: NSNotification.Name("QueueProcessingStateChanged"), object: nil)

		processingTask = Task {
			await processQueue()
		}
	}

	private func stopProcessing() {
		logger.info("⏹️ Stopping queue processing")

		processingTask?.cancel()
		processingTask = nil
		isProcessing = false
		currentItem = nil

		// Notify UI of processing state change
		NotificationCenter.default.post(
			name: NSNotification.Name("QueueProcessingStateChanged"), object: nil)
	}

	private func processQueue() async {
		logger.info("🔄 Processing transcription queue")

		while isProcessing {
			// Get next pending item
			guard let nextItem = pendingItems.first else {
				// No more pending items, processing complete
				break
			}

			// Check for cancellation
			if Task.isCancelled {
				logger.info("🛑 Queue processing cancelled")
				break
			}

			logger.info("🎯 Starting to process: \(nextItem.displayName)")
			await processItem(nextItem)
			logger.info("✅ Finished processing: \(nextItem.displayName)")

			// Small delay between items
			try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
		}

		// Processing complete
		isProcessing = false
		currentItem = nil
		logger.info("✅ Queue processing completed - no more pending items")

		// Notify UI of processing state change
		NotificationCenter.default.post(
			name: NSNotification.Name("QueueProcessingStateChanged"), object: nil)
	}

	private func processItem(_ item: TranscriptionQueueItem) async {
		logger.info("🎵 Processing: \(item.displayName)")

		currentItem = item
		item.status = QueueItemStatus.processing
		item.progress = 0.0

		// Create a task to track progress during transcription
		let progressTask = Task {
			while item.status == QueueItemStatus.processing {
				// Update item progress from file transcription manager
				await MainActor.run {
					item.progress = fileTranscriptionManager.progress
				}
				try? await Task.sleep(nanoseconds: 100_000_000)  // Update every 0.1 seconds
			}
		}

		do {
			// Determine if it's a YouTube URL, network URL, or local file
			if isYouTubeURL(item.url) {
				// YouTube URL - use YouTubeTranscriptionManager
				logger.info("🎬 Detected YouTube URL, using YouTube transcription")
				let youtubeManager = YouTubeTranscriptionManager(
					fileTranscriptionManager: fileTranscriptionManager,
					networkDownloader: networkDownloader
				)

				do {
					let videoInfo = try await youtubeManager.getVideoInfo(item.url)
					item.displayName = videoInfo.title
					logger.info("📺 Updated display name to: \(videoInfo.title)")
				} catch {
					logger.debug("⚠️ Could not get video title, keeping original display name")
				}

				let result = try await youtubeManager.transcribeYouTubeURL(item.url)

				item.result = result
				item.status = QueueItemStatus.completed
				item.progress = 1.0

				logger.info("✅ YouTube transcription completed: \(item.displayName)")

			} else if item.url.scheme == "http" || item.url.scheme == "https" {
				let result =
					try await networkDownloader.downloadAndTranscribe(
						from: item.url,
						using: fileTranscriptionManager,
						withTimestamps: false,
						deleteAfterTranscription: true
					) as! String

				item.result = result
				item.status = QueueItemStatus.completed
				item.progress = 1.0

				logger.info("✅ Network file transcription completed: \(item.displayName)")

			} else {
				let result = try await fileTranscriptionManager.transcribeFile(at: item.url)

				item.result = result
				item.status = QueueItemStatus.completed
				item.progress = 1.0
				logger.info("✅ Local file transcription completed: \(item.displayName)")
			}
			await saveTranscriptionResult(item.result ?? "", filename: item.displayName, item: item)
		} catch is CancellationError {
			logger.info("🛑 Transcription cancelled: \(item.displayName)")
			items.removeAll { $0.id == item.id }
		} catch {
			logger.error("❌ Transcription failed for \(item.displayName): \(error.localizedDescription)")
			item.status = QueueItemStatus.failed
			item.error = error.localizedDescription
		}
		progressTask.cancel()
		currentItem = nil
	}

	private func saveTranscriptionResult(
		_ text: String, filename: String, item: TranscriptionQueueItem
	) async {
		let outputPreference = UserDefaults.standard.string(forKey: "transcriptionOutput") ?? "both"

		switch outputPreference {
		case "clipboard":
			await copyToClipboard(text, filename: filename)
		case "file":
			await saveTranscriptionToFile(text, originalFilename: filename, item: item)
		case "both":
			await copyToClipboard(text, filename: filename)
			await saveTranscriptionToFile(text, originalFilename: filename, item: item)
		default:
			await copyToClipboard(text, filename: filename)
			await saveTranscriptionToFile(text, originalFilename: filename, item: item)
		}
	}

	private func copyToClipboard(_ text: String, filename: String) async {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		logger.info("📋 Transcription result copied to clipboard for: \(filename)")
	}

	// TODO: make it global
	private func saveTranscriptionToFile(
		_ transcription: String, originalFilename: String, item: TranscriptionQueueItem
	) async {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let timestamp = formatter.string(from: Date())

		let sanitizedOriginalName =
			originalFilename
			.replacingOccurrences(of: ".", with: "_")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: ":", with: "_")

		let transcriptionFilename = "transcription_\(sanitizedOriginalName)_\(timestamp).txt"

		let transcriptionLocation =
			UserDefaults.standard.string(forKey: "transcriptionFileLocation") ?? "Desktop"
		let customPath = UserDefaults.standard.string(forKey: "customTranscriptionPath") ?? ""

		logger.debug("📁 Transcription location setting: \(transcriptionLocation)")
		logger.debug("📁 Custom path setting: \(customPath)")

		let baseURL: URL
		switch transcriptionLocation {
		case "Documents":
			baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
			logger.info("📁 Using Documents directory: \(baseURL.path)")
		case "Downloads":
			baseURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
			logger.info("📁 Using Downloads directory: \(baseURL.path)")
		case "Custom":
			if !customPath.isEmpty && FileManager.default.fileExists(atPath: customPath) {
				baseURL = URL(fileURLWithPath: customPath)
				logger.info("📁 Using custom directory: \(baseURL.path)")
			} else {
				// Fallback to Desktop if custom path is invalid
				baseURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
				logger.debug(
					"⚠️ Custom transcription path '\(customPath)' is invalid or empty, falling back to Desktop"
				)
			}
		default:  // "Desktop"
			baseURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
			logger.info("📁 Using Desktop directory: \(baseURL.path)")
		}

		let fileURL = baseURL.appendingPathComponent(transcriptionFilename)

		do {
			try transcription.write(to: fileURL, atomically: true, encoding: .utf8)
			logger.info("💾 Transcription saved to: \(fileURL.path)")
			item.filePath = fileURL.path
			UserDefaults.standard.set(fileURL.path, forKey: "lastTranscriptionFilePath")
		} catch {
			logger.error("❌ Failed to save transcription to file: \(error.localizedDescription)")
		}
	}

	// MARK: - UI Actions
	func toggleExpanded() {
		withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
			isExpanded.toggle()
		}
	}
}
