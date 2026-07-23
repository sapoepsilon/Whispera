import Foundation
import Testing

@testable import Whispera

@MainActor
struct YouTubeQueueItemTests {

	// MARK: - Default Display Name

	@Test func youtubeWatchURLDefaultsToLastPathComponent() {
		let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
		let item = TranscriptionQueueItem(url: url)

		#expect(item.displayName == "watch")
		#expect(item.filename == "watch")
	}

	@Test func youtubeShortURLDefaultsToVideoID() {
		let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
		let item = TranscriptionQueueItem(url: url)

		#expect(item.displayName == "dQw4w9WgXcQ")
	}

	@Test func localFileURLDefaultsToFilename() {
		let url = URL(fileURLWithPath: "/tmp/recording.mp3")
		let item = TranscriptionQueueItem(url: url)

		#expect(item.displayName == "recording.mp3")
	}

	// MARK: - Custom Display Name

	@Test func customDisplayNameOverridesDefault() {
		let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
		let item = TranscriptionQueueItem(url: url, displayName: "Never Gonna Give You Up")

		#expect(item.displayName == "Never Gonna Give You Up")
		#expect(item.filename == "watch")
	}

	@Test func displayNameCanBeUpdatedAfterInit() {
		let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
		let item = TranscriptionQueueItem(url: url)

		#expect(item.displayName == "watch")

		item.displayName = "Actual Video Title"
		#expect(item.displayName == "Actual Video Title")
	}

	// MARK: - Initial State

	@Test func newItemStartsAsPending() {
		let url = URL(string: "https://www.youtube.com/watch?v=test")!
		let item = TranscriptionQueueItem(url: url)

		#expect(item.status == .pending)
		#expect(item.progress == 0.0)
		#expect(item.result == nil)
		#expect(item.error == nil)
		#expect(item.filePath == nil)
	}

	// MARK: - QueueItemStatus

	@Test func statusDisplayNames() {
		#expect(QueueItemStatus.pending.displayName == "Pending")
		#expect(QueueItemStatus.processing.displayName == "Processing")
		#expect(QueueItemStatus.completed.displayName == "Completed")
		#expect(QueueItemStatus.failed.displayName == "Failed")
		#expect(QueueItemStatus.cancelled.displayName == "Cancelled")
	}

	// MARK: - Queue Manager Item Management

	@Test func addFilesWithDisplayNamesPreservesNames() {
		let manager = TranscriptionQueueManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
		// Prevent auto-processing so we can inspect items
		manager.isProcessing = true

		let urls = [
			URL(string: "https://www.youtube.com/watch?v=abc123")!,
			URL(string: "https://www.youtube.com/watch?v=def456")!,
		]
		let names = ["First Video Title", "Second Video Title"]

		manager.addFiles(urls, displayNames: names)

		#expect(manager.items.count == 2)
		#expect(manager.items[0].displayName == "First Video Title")
		#expect(manager.items[1].displayName == "Second Video Title")
	}

	@Test func addFilesWithoutNamesUsesURLLastComponent() {
		let manager = TranscriptionQueueManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
		manager.isProcessing = true

		manager.addFiles([URL(string: "https://www.youtube.com/watch?v=abc123")!])

		#expect(manager.items.count == 1)
		#expect(manager.items[0].displayName == "watch")
	}

	@Test func clearAllRemovesItems() {
		let manager = TranscriptionQueueManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
		manager.isProcessing = true

		manager.addFiles([
			URL(string: "https://www.youtube.com/watch?v=abc123")!,
			URL(string: "https://www.youtube.com/watch?v=def456")!,
		])

		#expect(manager.items.count == 2)

		manager.clearAll()
		#expect(manager.items.isEmpty)
	}
}
