import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DropInfo {
	let providers: [NSItemProvider]

	func hasItemsConforming(to types: [UTType]) -> Bool {
		for type in types {
			if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) {
				return true
			}
		}
		return false
	}

	func itemProviders(for types: [UTType]) -> [NSItemProvider] {
		return providers.filter { provider in
			types.contains { type in
				provider.hasItemConformingToTypeIdentifier(type.identifier)
			}
		}
	}
}

@MainActor
@Observable
class FileDropHandler: DragDropHandler {

	var isDragging: Bool = false
	var acceptedFileTypes: Set<String> = Set(SupportedFileTypes.allFormats)

	var draggedItemsCount: Int = 0
	var draggedItemsPreview: String = ""
	var isValidDrop: Bool = false

	private let fileTranscriptionManager: FileTranscriptionManager
	private let networkDownloader: NetworkFileDownloader
	private let logger = AppLogger.shared.ui
	private weak var queueManager: TranscriptionQueueManager?

	private var autoDeleteDownloadedFiles: Bool {
		UserDefaults.standard.bool(forKey: "autoDeleteDownloadedFiles")
	}

	init(
		fileTranscriptionManager: FileTranscriptionManager,
		networkDownloader: NetworkFileDownloader,
		queueManager: TranscriptionQueueManager? = nil
	) {
		self.fileTranscriptionManager = fileTranscriptionManager
		self.networkDownloader = networkDownloader
		self.queueManager = queueManager
	}

	func setQueueManager(_ queueManager: TranscriptionQueueManager) {
		self.queueManager = queueManager
	}

	func canAccept(_ info: DropInfo) -> Bool {
		logger.info("🔍 Checking if drop can be accepted")

		draggedItemsCount = 0
		draggedItemsPreview = ""
		isValidDrop = false

		if info.hasItemsConforming(to: [.fileURL]) {
			// Can't validate file URLs synchronously - validation happens on drop
			let providers = info.itemProviders(for: [.fileURL])
			if !providers.isEmpty {
				draggedItemsCount = providers.count
				draggedItemsPreview = providers.count == 1 ? "File" : "\(providers.count) files"
				isValidDrop = true
				logger.info("✅ Accepting \(providers.count) file(s) - will validate on drop")
				return true
			}
		}

		if info.hasItemsConforming(to: [.url]) {
			let providers = info.itemProviders(for: [.url])
			if !providers.isEmpty {
				draggedItemsCount = providers.count
				draggedItemsPreview = providers.count == 1 ? "URL" : "\(providers.count) URLs"
				isValidDrop = true
				logger.info("✅ Accepting \(providers.count) URL item(s)")
				return true
			}
		}

		if info.hasItemsConforming(to: [.text, .plainText]) {
			return validateTextItems(info)
		}

		if info.providers.contains(where: hasPotentialURLPayload) {
			draggedItemsCount = max(1, info.providers.count)
			draggedItemsPreview = draggedItemsCount == 1 ? "URL" : "\(draggedItemsCount) URLs"
			isValidDrop = true
			logger.info("✅ Accepting provider with URL-like payload")
			return true
		}

		// Fallback: read directly from the macOS drag pasteboard
		// Safari and some other apps provide URLs via pasteboard types that
		// NSItemProvider doesn't bridge properly
		let pasteboardURLs = readURLsFromDragPasteboard()
		if !pasteboardURLs.isEmpty {
			draggedItemsCount = pasteboardURLs.count
			draggedItemsPreview = pasteboardURLs.count == 1 ? "URL" : "\(pasteboardURLs.count) URLs"
			isValidDrop = true
			logger.info("✅ Accepting \(pasteboardURLs.count) URL(s) from drag pasteboard (fallback)")
			return true
		}

		logger.info("❌ Drop rejected - no supported items found")
		logger.info("📋 Provider type identifiers: \(info.providers.flatMap { $0.registeredTypeIdentifiers })")
		return false
	}

	func handleDrop(_ info: DropInfo) async -> Bool {
		logger.info("📁 Handling drop operation")

		if info.hasItemsConforming(to: [.fileURL]) {
			let fileURLs = await getFileURLsAsync(from: info)

			let validURLs = fileURLs.filter { url in
				let fileExtension = url.pathExtension.lowercased()
				let isSupported = self.acceptedFileTypes.contains(fileExtension)
				self.logger.info(
					"🔍 Validating dropped file: \(url.lastPathComponent), extension: .\(fileExtension), supported: \(isSupported)"
				)
				return isSupported
			}

			if !validURLs.isEmpty {
				if let queueManager = queueManager {
					queueManager.addFiles(validURLs)
					logger.info("✅ Added \(validURLs.count) files to transcription queue")
				} else {
					await transcribeFiles(validURLs)
				}
				return true
			} else if !fileURLs.isEmpty {
				logger.error("❌ No supported file formats in dropped files")
				await showError(
					"Unsupported file format. Supported formats: \(SupportedFileTypes.formattedDescription)")
				return false
			}
		}

		if info.hasItemsConforming(to: [.text, .plainText]) {
			let urls = await getTextURLs(from: info)
			if !urls.isEmpty {
				if let queueManager = queueManager {
					queueManager.addFiles(urls)
					logger.info("✅ Added \(urls.count) URLs to transcription queue")
				} else {
					await transcribeNetworkFiles(urls)
				}
				return true
			}
		}

		if info.hasItemsConforming(to: [.url]) {
			let urls = await getURLItems(from: info)
			if !urls.isEmpty {
				if let queueManager = queueManager {
					queueManager.addFiles(urls)
					logger.info("✅ Added \(urls.count) URLs to transcription queue")
				} else {
					await transcribeNetworkFiles(urls)
				}
				return true
			}
		}

		let fallbackURLs = await getFallbackURLs(from: info)
		if !fallbackURLs.isEmpty {
			if let queueManager = queueManager {
				queueManager.addFiles(fallbackURLs)
				logger.info("✅ Added \(fallbackURLs.count) fallback URL(s) to transcription queue")
			} else {
				await transcribeNetworkFiles(fallbackURLs)
			}
			return true
		}

		// Last resort: read directly from the macOS drag pasteboard (handles Safari)
		let pasteboardURLs = readURLsFromDragPasteboard()
		if !pasteboardURLs.isEmpty {
			let fileURLs = pasteboardURLs.filter { $0.isFileURL }
			let webURLs = pasteboardURLs.filter { !$0.isFileURL }

			if !fileURLs.isEmpty {
				let validFiles = fileURLs.filter { acceptedFileTypes.contains($0.pathExtension.lowercased()) }
				if !validFiles.isEmpty {
					if let queueManager = queueManager {
						queueManager.addFiles(validFiles)
						logger.info("✅ Added \(validFiles.count) file(s) from drag pasteboard to queue")
					} else {
						await transcribeFiles(validFiles)
					}
					return true
				}
			}

			if !webURLs.isEmpty {
				if let queueManager = queueManager {
					queueManager.addFiles(webURLs)
					logger.info("✅ Added \(webURLs.count) URL(s) from drag pasteboard to queue")
				} else {
					await transcribeNetworkFiles(webURLs)
				}
				return true
			}
		}

		logger.error("❌ Drop handling failed - no valid items")
		return false
	}

	func dragEntered() {
		isDragging = true
		isValidDrop = true
		draggedItemsCount = 1
		draggedItemsPreview = "file(s)"
		logger.info("🎯 Drag entered drop zone")
	}

	func dragExited() {
		isDragging = false
		draggedItemsCount = 0
		draggedItemsPreview = ""
		isValidDrop = false
		logger.info("🚪 Drag exited drop zone")
	}

	func dragUpdated(_ info: DropInfo) {
		if info.hasItemsConforming(to: [.fileURL]) {
			let providers = info.itemProviders(for: [.fileURL])
			draggedItemsCount = providers.count
			draggedItemsPreview = providers.count == 1 ? "File" : "\(providers.count) files"
			isValidDrop = true
		} else if info.hasItemsConforming(to: [.text, .plainText]) {
			draggedItemsCount = 1
			draggedItemsPreview = "URL"
			isValidDrop = true
		} else if info.hasItemsConforming(to: [.url]) {
			let providers = info.itemProviders(for: [.url])
			draggedItemsCount = max(1, providers.count)
			draggedItemsPreview = draggedItemsCount == 1 ? "URL" : "\(draggedItemsCount) URLs"
			isValidDrop = true
		}
	}

	private func getURLItems(from info: DropInfo) async -> [URL] {
		var urls: [URL] = []

		for provider in info.itemProviders(for: [.url]) {
			do {
				let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)

				if let url = item as? URL, !url.isFileURL {
					urls.append(url)
				} else if let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					!url.isFileURL
				{
					urls.append(url)
				} else if let string = item as? String,
					let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
					!url.isFileURL
				{
					urls.append(url)
				}
			} catch {
				logger.error("❌ Failed to load URL item: \(error.localizedDescription)")
			}
		}

		return urls.filter { $0.scheme == "http" || $0.scheme == "https" }
	}

	private func getFallbackURLs(from info: DropInfo) async -> [URL] {
		var urls: [URL] = []

		for provider in info.providers {
			for typeIdentifier in provider.registeredTypeIdentifiers {
				guard typeIdentifier.contains("url") || typeIdentifier.contains("text") else {
					continue
				}

				do {
					let item = try await provider.loadItem(forTypeIdentifier: typeIdentifier)
					if let extracted = extractURL(from: item) {
						urls.append(extracted)
						break
					}
				} catch {
					logger.error("❌ Failed to load fallback item (\(typeIdentifier)): \(error.localizedDescription)")
				}
			}
		}

		return urls.filter { $0.scheme == "http" || $0.scheme == "https" }
	}

	private func hasPotentialURLPayload(_ provider: NSItemProvider) -> Bool {
		provider.registeredTypeIdentifiers.contains { typeIdentifier in
			typeIdentifier.contains("url") || typeIdentifier.contains("text")
		}
	}

	/// Reads URLs directly from the macOS drag pasteboard, bypassing NSItemProvider.
	/// Safari and some apps provide URLs via pasteboard types that SwiftUI's
	/// NSItemProvider bridge doesn't handle.
	private func readURLsFromDragPasteboard() -> [URL] {
		let pasteboard = NSPasteboard(name: .drag)

		if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
			let httpURLs = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
			if !httpURLs.isEmpty {
				logger.info("📋 Read \(httpURLs.count) URL(s) from drag pasteboard via NSURL")
				return httpURLs
			}
		}

		if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] {
			let urls = strings.compactMap { string -> URL? in
				let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
				guard let url = URL(string: trimmed),
					url.scheme == "http" || url.scheme == "https"
				else {
					return nil
				}
				return url
			}
			if !urls.isEmpty {
				logger.info("📋 Read \(urls.count) URL(s) from drag pasteboard via string parsing")
				return urls
			}
		}

		return []
	}

	private func extractURL(from item: NSSecureCoding?) -> URL? {
		if let url = item as? URL, !url.isFileURL {
			return url
		}

		if let data = item as? Data,
			let url = URL(dataRepresentation: data, relativeTo: nil),
			!url.isFileURL
		{
			return url
		}

		if let string = item as? String {
			let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
			if let url = URL(string: trimmed), !url.isFileURL {
				return url
			}
		}

		if let nsString = item as? NSString {
			let trimmed = (nsString as String).trimmingCharacters(in: .whitespacesAndNewlines)
			if let url = URL(string: trimmed), !url.isFileURL {
				return url
			}
		}

		return nil
	}

	private func getFileURLsAsync(from info: DropInfo) async -> [URL] {
		var urls: [URL] = []

		for provider in info.itemProviders(for: [.fileURL]) {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				do {
					let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
					if let data = item as? Data,
						let url = URL(dataRepresentation: data, relativeTo: nil)
					{
						urls.append(url)
					} else if let url = item as? URL {
						urls.append(url)
					}
				} catch {
					logger.error("❌ Failed to load file URL: \(error)")
				}
			}
		}

		return urls
	}

	private func getTextURLs(from info: DropInfo) async -> [URL] {
		var urls: [URL] = []

		logger.info("🔍 Processing text items for URLs...")
		logger.info("📋 Available providers: \(info.providers.count)")

		for (index, provider) in info.itemProviders(for: [.text, .plainText]).enumerated() {
			logger.info("🔍 Processing provider \(index + 1)")
			logger.info("📝 Provider types: \(provider.registeredTypeIdentifiers)")

			var foundText = false

			// Method 1: Try loadObject(ofClass: NSString.self) - preferred for strings
			if provider.canLoadObject(ofClass: NSString.self) {
				logger.info("✅ Provider can load NSString object")
				do {
					let stringObject: NSString = try await withCheckedThrowingContinuation {
						(continuation: CheckedContinuation<NSString, Error>) in
						_ = provider.loadObject(ofClass: NSString.self) { object, error in
							if let error = error {
								continuation.resume(throwing: error)
							} else if let string = object as? NSString {
								continuation.resume(returning: string)
							} else {
								continuation.resume(
									throwing: NSError(
										domain: "FileDropHandler", code: -1,
										userInfo: [
											NSLocalizedDescriptionKey:
												"Failed to cast object to NSString"
										]))
							}
						}
					}
					let text = stringObject as String
					logger.info("📝 Found text content via NSString: \(text)")
					foundText = true

					let extractedURLs = extractURLsFromText(text)
					urls.append(contentsOf: extractedURLs)

				} catch {
					logger.error("❌ Failed to load NSString object: \(error.localizedDescription)")
				}
			}

			// Method 2: Try loadItem with data handling if NSString method failed
			if !foundText {
				let textTypes = [
					UTType.plainText.identifier,
					UTType.text.identifier,
					UTType.utf8PlainText.identifier,
					"public.text",
					"public.plain-text",
					"public.utf8-plain-text",
				]

				for textType in textTypes {
					if provider.hasItemConformingToTypeIdentifier(textType) {
						logger.info("✅ Provider has type: \(textType)")

						do {
							let item = try await provider.loadItem(
								forTypeIdentifier: textType, options: nil)
							var text: String?

							// Handle different possible return types
							if let stringItem = item as? String {
								text = stringItem
								logger.info("📝 Found text as String for type: \(textType)")
							} else if let dataItem = item as? Data {
								text = String(data: dataItem, encoding: .utf8)
								logger.info("📝 Found text as Data for type: \(textType)")
							} else if let nsStringItem = item as? NSString {
								text = nsStringItem as String
								logger.info("📝 Found text as NSString for type: \(textType)")
							} else {
								logger.info("❌ Unknown item type for \(textType): \(type(of: item))")
							}

							if let text = text {
								logger.info("📝 Successfully extracted text (\(textType)): \(text)")
								foundText = true

								// Process the text for URLs
								let extractedURLs = extractURLsFromText(text)
								urls.append(contentsOf: extractedURLs)
								break  // Found text, no need to try other types
							}

						} catch {
							logger.error(
								"❌ Failed to load text item for type \(textType): \(error.localizedDescription)"
							)
						}
					}
				}
			}

			if !foundText {
				logger.info("⚠️ No text content found in provider \(index + 1)")
			}
		}

		logger.info("✅ Extracted \(urls.count) URLs from text")
		return urls
	}

	private func extractURLsFromText(_ text: String) -> [URL] {
		var urls: [URL] = []

		// Split by newlines and whitespace to handle multiple URLs
		let lines = text.components(separatedBy: .newlines)
		for line in lines {
			let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if let url = URL(string: trimmedLine),
				url.scheme == "http" || url.scheme == "https"
			{
				logger.info("🔗 Found valid URL: \(url.absoluteString)")
				urls.append(url)
			} else if !trimmedLine.isEmpty {
				logger.info("❌ Invalid URL format: '\(trimmedLine)'")
			}
		}

		return urls
	}

	private func validateTextItems(_ info: DropInfo) -> Bool {
		// For performance, we'll do a quick check here and full validation later
		draggedItemsCount = 1
		draggedItemsPreview = "URL"
		isValidDrop = true

		logger.info("✅ Text items appear to be valid URLs")
		return true
	}

	private func transcribeFiles(_ urls: [URL]) async {
		logger.info("🎵 Starting transcription for \(urls.count) file(s)")

		do {
			if urls.count == 1 {
				let result = try await fileTranscriptionManager.transcribeFile(at: urls[0])
				await copyToClipboard(result, filename: urls[0].lastPathComponent)
				logger.info("✅ Single file transcription completed")
			} else {
				let results = try await fileTranscriptionManager.transcribeFiles(at: urls)
				let combinedResult = zip(urls, results).map { url, result in
					"File: \(url.lastPathComponent)\n\(result)"
				}.joined(separator: "\n\n" + String(repeating: "-", count: 50) + "\n\n")

				await copyToClipboard(combinedResult, filename: "Multiple Files")
				logger.info("✅ Batch file transcription completed")
			}
		} catch {
			logger.error("❌ File transcription failed: \(error.localizedDescription)")
			await showError("File transcription failed: \(error.localizedDescription)")
		}
	}

	private func transcribeNetworkFiles(_ urls: [URL]) async {
		logger.info("🌐 Starting network file transcription for \(urls.count) URL(s)")

		for (index, url) in urls.enumerated() {
			do {
				logger.info("⬇️ Processing URL \(index + 1)/\(urls.count): \(url.absoluteString)")

				// Check if it's a YouTube URL
				if isYouTubeURL(url) {
					logger.info("🎬 Detected YouTube URL, using YouTube transcription")
					let youtubeManager = YouTubeTranscriptionManager(
						fileTranscriptionManager: fileTranscriptionManager,
						networkDownloader: networkDownloader
					)
					let result = try await youtubeManager.transcribeYouTubeURL(url)
					let filename = "YouTube Video"
					await copyToClipboard(result, filename: filename)
				} else {
					// Handle as regular network file
					let result: String =
						try await networkDownloader.downloadAndTranscribe(
							from: url,
							using: fileTranscriptionManager,
							withTimestamps: false,
							deleteAfterTranscription: autoDeleteDownloadedFiles
						) as! String

					let filename = url.lastPathComponent.isEmpty ? "Network File" : url.lastPathComponent
					await copyToClipboard(result, filename: filename)
				}

				logger.info("✅ Network file transcription completed for: \(url.absoluteString)")

			} catch {
				logger.error(
					"❌ Network file transcription failed for \(url.absoluteString): \(error.localizedDescription)"
				)
				await showError(
					"Network transcription failed for \(url.absoluteString): \(error.localizedDescription)")
			}
		}
	}

	private func isYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
			|| host == "m.youtube.com"
	}

	private func copyToClipboard(_ text: String, filename: String) async {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)

		logger.info("📋 Transcription result copied to clipboard for: \(filename)")

		// Offer to save to file as well
		await saveTranscriptionToFile(text, originalFilename: filename)

		// Show success notification
		await showSuccess(
			"Transcription completed for \(filename). Result copied to clipboard and saved to file.")
	}

	private func saveTranscriptionToFile(_ transcription: String, originalFilename: String) async {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
		let timestamp = formatter.string(from: Date())

		let sanitizedOriginalName =
			originalFilename
			.replacingOccurrences(of: ".", with: "_")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: ":", with: "_")

		let transcriptionFilename = "transcription_\(sanitizedOriginalName)_\(timestamp).txt"

		// Get the user's Desktop directory
		let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
		let fileURL = desktopURL.appendingPathComponent(transcriptionFilename)

		do {
			try transcription.write(to: fileURL, atomically: true, encoding: .utf8)
			logger.info("💾 Transcription saved to: \(fileURL.path)")
		} catch {
			logger.error("❌ Failed to save transcription to file: \(error.localizedDescription)")
			await showError("Failed to save transcription to file: \(error.localizedDescription)")
		}
	}

	private func showSuccess(_ message: String) async {
		logger.info("✅ Success: \(message)")

		// Send notification through NotificationCenter for UI updates
		NotificationCenter.default.post(
			name: .fileTranscriptionSuccess,
			object: nil,
			userInfo: ["message": message]
		)
	}

	private func showError(_ message: String) async {
		logger.error("❌ Error: \(message)")

		// Send notification through NotificationCenter for UI updates
		NotificationCenter.default.post(
			name: .fileTranscriptionError,
			object: nil,
			userInfo: ["message": message]
		)
	}
}

extension Notification.Name {
	static let fileTranscriptionSuccess = Notification.Name("fileTranscriptionSuccess")
	static let fileTranscriptionError = Notification.Name("fileTranscriptionError")
}

extension FileDropHandler {

	var dropZoneText: String {
		if isDragging {
			// Always show optimistic message during drag
			// We can't validate file types until drop actually happens
			if draggedItemsCount == 1 {
				return "Drop to transcribe"
			} else {
				return "Drop \(draggedItemsCount) items to transcribe"
			}
		} else {
			return "Drop audio/video files or URLs here"
		}
	}

	var dropZoneColor: Color {
		if isDragging {
			// Always show green during drag since we can't validate yet
			return .green.opacity(0.3)
		} else {
			return .secondary.opacity(0.1)
		}
	}

	var dropZoneIcon: String {
		if isDragging {
			// Always show checkmark during drag since we can't validate yet
			return "checkmark.circle.fill"
		} else {
			return "doc.on.doc.fill"
		}
	}
}
