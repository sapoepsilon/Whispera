import Foundation
import Testing

@testable import Whispera

@MainActor
struct YouTubeVideoInfoTests {

	private let testVideoURL = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
	private let testVideoID = "jNQXAC9IVRw"

	private func makeManager() -> YouTubeTranscriptionManager {
		YouTubeTranscriptionManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
	}

	// MARK: - Video Info Retrieval

	@Test func getVideoInfoReturnsNonEmptyTitle() async throws {
		let manager = makeManager()
		let info = try await manager.getVideoInfo(testVideoURL)

		#expect(!info.title.isEmpty)
		#expect(info.title != "watch")
		#expect(info.videoID == testVideoID)
	}

	@Test func getVideoInfoReturnsMatchingVideoID() async throws {
		let manager = makeManager()
		let info = try await manager.getVideoInfo(testVideoURL)

		#expect(info.videoID == testVideoID)
		#expect(!info.title.isEmpty)
		#expect(info.title != "YouTube Video (\(testVideoID))")
	}

	@Test func getVideoInfoWithShortURL() async throws {
		let manager = makeManager()
		let shortURL = URL(string: "https://youtu.be/\(testVideoID)")!
		let info = try await manager.getVideoInfo(shortURL)

		#expect(!info.title.isEmpty)
		#expect(info.videoID == testVideoID)
	}

	@Test func getVideoInfoWithMobileURL() async throws {
		let manager = makeManager()
		let mobileURL = URL(string: "https://m.youtube.com/watch?v=\(testVideoID)")!
		let info = try await manager.getVideoInfo(mobileURL)

		#expect(!info.title.isEmpty)
		#expect(info.videoID == testVideoID)
	}

	@Test func getVideoInfoRejectsNonYouTubeURL() async {
		let manager = makeManager()
		let badURL = URL(string: "https://example.com/video.mp4")!

		await #expect(throws: YouTubeTranscriptionError.self) {
			try await manager.getVideoInfo(badURL)
		}
	}

	// MARK: - Queue Display Name Flow

	@Test func queueItemDisplayNameUpdatedFromVideoInfo() async throws {
		let manager = makeManager()
		let info = try await manager.getVideoInfo(testVideoURL)

		let item = TranscriptionQueueItem(url: testVideoURL)
		#expect(item.displayName == "watch")

		item.displayName = info.title
		#expect(item.displayName != "watch")
		#expect(item.displayName == info.title)
	}

	// MARK: - Prefetched Info Parameter

	@Test func prefetchedInfoMatchesAcrossURLFormats() async throws {
		let manager = makeManager()
		let watchInfo = try await manager.getVideoInfo(testVideoURL)

		let shortURL = URL(string: "https://youtu.be/\(testVideoID)")!
		let shortInfo = try await manager.getVideoInfo(shortURL)

		#expect(watchInfo.videoID == shortInfo.videoID)
		#expect(watchInfo.title == shortInfo.title)
	}
}

@MainActor
struct YouTubeDownloadTranscriptionTests {

	private let testVideoURL = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
	private let testVideoID = "jNQXAC9IVRw"

	private func makeManager() -> YouTubeTranscriptionManager {
		YouTubeTranscriptionManager(
			fileTranscriptionManager: FileTranscriptionManager(),
			networkDownloader: NetworkFileDownloader()
		)
	}

	@Test(.timeLimit(.minutes(3)))
	func downloadAndTranscribeYouTubeVideo() async throws {
		let manager = makeManager()
		let result = try await manager.transcribeYouTubeURL(testVideoURL)

		#expect(!result.isEmpty)
		#expect(manager.videoInfo != nil)
		#expect(manager.videoInfo?.videoID == testVideoID)
	}

	@Test(.timeLimit(.minutes(3)))
	func downloadAndTranscribeWithPrefetchedInfo() async throws {
		let manager = makeManager()
		let info = try await manager.getVideoInfo(testVideoURL)

		let result = try await manager.transcribeYouTubeURL(testVideoURL, prefetchedInfo: info)

		#expect(!result.isEmpty)
		#expect(manager.videoInfo?.title == info.title)
	}

	@Test(.timeLimit(.minutes(3)))
	func queueManagerProcessesYouTubeWithTitle() async throws {
		let fileManager = FileTranscriptionManager()
		let downloader = NetworkFileDownloader()
		let queueManager = TranscriptionQueueManager(
			fileTranscriptionManager: fileManager,
			networkDownloader: downloader
		)

		queueManager.addFiles([testVideoURL])

		while queueManager.isProcessing || !queueManager.pendingItems.isEmpty {
			try await Task.sleep(nanoseconds: 500_000_000)
		}

		#expect(queueManager.items.count == 1)
		let item = queueManager.items[0]
		#expect(item.status == .completed)
		#expect(item.displayName != "watch")
		#expect(!item.displayName.isEmpty)
		#expect(item.result != nil)
		#expect(!(item.result?.isEmpty ?? true))
	}
}
