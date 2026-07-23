import ApplicationServices
import Cocoa
import Foundation
import SwiftUI

class GlobalShortcutManager: ObservableObject {
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var fileSelectionGlobalMonitor: Any?
	private var fileSelectionLocalMonitor: Any?
	private var audioManager: AudioManager?
	private var fileTranscriptionManager: FileTranscriptionManager?
	private var networkDownloader: NetworkFileDownloader?
	private var queueManager: TranscriptionQueueManager?
	private var isProcessingFileOperation = false
	private let logger = AppLogger.shared.general
	var currentShortcut: String = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"
	var fileSelectionShortcut: String =
		UserDefaults.standard.string(forKey: "fileSelectionShortcut") ?? "⌃F"

	// MARK: - Settings
	private var autoDeleteDownloadedFiles: Bool {
		UserDefaults.standard.bool(forKey: "autoDeleteDownloadedFiles")
	}

	init() {
		setupShortcut()
		NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			let newShortcut = UserDefaults.standard.string(forKey: "globalShortcut") ?? "⌃A"
			let newFileShortcut = UserDefaults.standard.string(forKey: "fileSelectionShortcut") ?? "⌃F"

			if newShortcut != self?.currentShortcut {
				self?.logger.info(
					"Text shortcut changed: \(self?.currentShortcut ?? "nil") → \(newShortcut)")
				self?.currentShortcut = newShortcut
				self?.setupShortcut()
			}

			if newFileShortcut != self?.fileSelectionShortcut {
				self?.logger.info(
					"File selection shortcut changed: \(self?.fileSelectionShortcut ?? "nil") → \(newFileShortcut)"
				)
				self?.fileSelectionShortcut = newFileShortcut
				self?.setupShortcut()
			}
		}
	}

	func setAudioManager(_ manager: AudioManager) {
		self.audioManager = manager
		logger.info("AudioManager set, checking accessibility status...")
		checkAccessibilityStatus()
	}

	func setFileTranscriptionManager(_ manager: FileTranscriptionManager) {
		self.fileTranscriptionManager = manager
		logger.info("FileTranscriptionManager set")
	}

	func setNetworkDownloader(_ downloader: NetworkFileDownloader) {
		self.networkDownloader = downloader
		logger.info("NetworkFileDownloader set")
	}

	func setQueueManager(_ manager: TranscriptionQueueManager) {
		self.queueManager = manager
		logger.info("TranscriptionQueueManager set")
	}

	func checkAccessibilityStatus() {
		let hasPermissions = AXIsProcessTrusted()
		logger.info("Current accessibility permissions: \(hasPermissions)")
		logger.info("Text shortcut: \(currentShortcut)")
		logger.info("File selection shortcut: \(fileSelectionShortcut)")
		logger.info(
			"Global monitors active - Text: \(globalMonitor != nil), File: \(fileSelectionGlobalMonitor != nil)"
		)

		if !hasPermissions {
			logger.error("PROBLEM: No accessibility permissions - shortcuts will NOT work")
			logger.error("Go to System Settings > Privacy & Security > Accessibility")
			logger.error("Add Whispera to the list and enable it")
		} else if globalMonitor == nil || fileSelectionGlobalMonitor == nil {
			logger.error("PROBLEM: Some global monitors not set up despite having permissions")
			setupShortcut()
		}
	}

	private func setupShortcut() {
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
			self.globalMonitor = nil
			logger.info("Removed old text global monitor")
		}
		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
			self.localMonitor = nil
			logger.info("Removed old text local monitor")
		}
		if let monitor = fileSelectionGlobalMonitor {
			NSEvent.removeMonitor(monitor)
			self.fileSelectionGlobalMonitor = nil
			logger.info("Removed old file selection global monitor")
		}
		if let monitor = fileSelectionLocalMonitor {
			NSEvent.removeMonitor(monitor)
			self.fileSelectionLocalMonitor = nil
			logger.info("Removed old file selection local monitor")
		}

		let (textModifiers, textKeyCode) = parseShortcut(currentShortcut)
		logger.info(
			"Setting up text shortcut for \(currentShortcut) (keyCode: \(textKeyCode), modifiers: \(textModifiers.rawValue))"
		)

		let (fileModifiers, fileKeyCode) = parseShortcut(fileSelectionShortcut)
		logger.info(
			"Setting up file selection shortcut for \(fileSelectionShortcut) (keyCode: \(fileKeyCode), modifiers: \(fileModifiers.rawValue))"
		)

		logger.info("Installing global monitors...")
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			if self?.matchesShortcut(
				event: event, expectedModifiers: textModifiers, expectedKeyCode: textKeyCode) == true
			{
				self?.logger.info("Global text shortcut detected!")
				self?.handleTextHotKey()
			} else if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Global file selection shortcut detected!")
				self?.handleFileSelectionHotKey()
			}
		}

		fileSelectionGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
			[weak self] event in
			if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Global file selection shortcut detected (dedicated monitor)!")
				self?.handleFileSelectionHotKey()
			}
		}

		// Also set up local monitors as fallback (works when app is focused)
		logger.info("Installing local monitors as fallback...")
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			if self?.matchesShortcut(
				event: event, expectedModifiers: textModifiers, expectedKeyCode: textKeyCode) == true
			{
				self?.logger.info("Local text shortcut detected!")
				self?.handleTextHotKey()
				return nil  // Consume the event
			} else if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Local file selection shortcut detected!")
				self?.handleFileSelectionHotKey()
				return nil  // Consume the event
			}
			return event
		}

		fileSelectionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
			[weak self] event in
			if self?.matchesShortcut(
				event: event, expectedModifiers: fileModifiers, expectedKeyCode: fileKeyCode) == true
			{
				self?.logger.info("Local file selection shortcut detected (dedicated monitor)!")
				self?.handleFileSelectionHotKey()
				return nil  // Consume the event
			}
			return event
		}

		logger.info(
			"Monitors installed - Text Global: \(globalMonitor != nil), Text Local: \(localMonitor != nil)"
		)
		logger.info(
			"File monitors installed - File Global: \(fileSelectionGlobalMonitor != nil), File Local: \(fileSelectionLocalMonitor != nil)"
		)
	}

	private func parseShortcut(_ shortcut: String) -> (NSEvent.ModifierFlags, UInt16) {
		var modifiers: NSEvent.ModifierFlags = []
		var keyChar = ""

		logger.debug("Parsing shortcut: '\(shortcut)'")

		if shortcut.contains("⌘") { modifiers.insert(.command) }
		if shortcut.contains("⌥") { modifiers.insert(.option) }
		if shortcut.contains("⌃") { modifiers.insert(.control) }
		if shortcut.contains("⇧") { modifiers.insert(.shift) }

		// Extract the key character (everything after modifiers)
		let modifierSymbols = "⌘⌥⌃⇧"
		var remainingShortcut = shortcut

		// Remove all modifier symbols from the beginning
		for symbol in modifierSymbols {
			remainingShortcut = remainingShortcut.replacingOccurrences(of: String(symbol), with: "")
		}

		keyChar = remainingShortcut.trimmingCharacters(in: .whitespaces)

		let keyCode = keyCodeForCharacter(keyChar.lowercased())
		logger.debug(
			"Parsed: keyChar='\(keyChar)', keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
		return (modifiers, keyCode)
	}

	private func keyCodeForCharacter(_ char: String) -> UInt16 {
		// Map common characters and special keys to key codes
		switch char.lowercased() {
		// Letters
		case "a": return 0
		case "b": return 11
		case "c": return 8
		case "d": return 2
		case "e": return 14
		case "f": return 3
		case "g": return 5
		case "h": return 4
		case "i": return 34
		case "j": return 38
		case "k": return 40
		case "l": return 37
		case "m": return 46
		case "n": return 45
		case "o": return 31
		case "p": return 35
		case "q": return 12
		case "r": return 15
		case "s": return 1
		case "t": return 17
		case "u": return 32
		case "v": return 9
		case "w": return 13
		case "x": return 7
		case "y": return 16
		case "z": return 6

		// Numbers
		case "0": return 29
		case "1": return 18
		case "2": return 19
		case "3": return 20
		case "4": return 21
		case "5": return 23
		case "6": return 22
		case "7": return 26
		case "8": return 28
		case "9": return 25

		// Function keys
		case "f1": return 122
		case "f2": return 120
		case "f3": return 99
		case "f4": return 118
		case "f5": return 96
		case "f6": return 97
		case "f7": return 98
		case "f8": return 100
		case "f9": return 101
		case "f10": return 109
		case "f11": return 103
		case "f12": return 111
		case "f13": return 105
		case "f14": return 107
		case "f15": return 113
		case "f16": return 106
		case "f17": return 64
		case "f18": return 79
		case "f19": return 80
		case "f20": return 90

		// Special keys
		case "space", " ": return 49
		case "return", "enter", "↩": return 36
		case "tab", "⇥": return 48
		case "delete", "⌫": return 51
		case "escape", "esc", "⎋": return 53
		case "home", "↖": return 115
		case "end", "↘": return 119
		case "pageup", "⇞": return 116
		case "pagedown", "⇟": return 121
		case "up", "↑": return 126
		case "down", "↓": return 125
		case "left", "←": return 123
		case "right", "→": return 124
		case "clear", "⌧": return 71
		case "help", "?⃝": return 114

		// Punctuation
		case "-": return 27
		case "=": return 24
		case "[": return 33
		case "]": return 30
		case "\\": return 42
		case ";": return 41
		case "'": return 39
		case ",": return 43
		case ".": return 47
		case "/": return 44
		case "`": return 50

		// Globe/Fn key (on newer Macs)
		case "globe", "fn", "🌐": return 63

		default: return 15  // Default to 'R' key
		}
	}

	private func matchesShortcut(
		event: NSEvent, expectedModifiers: NSEvent.ModifierFlags, expectedKeyCode: UInt16
	) -> Bool {
		return event.modifierFlags.intersection([.command, .option, .control, .shift])
			== expectedModifiers && event.keyCode == expectedKeyCode
	}

	func requestAccessibilityPermissions() {
		logger.info("Requesting accessibility permissions...")
		let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
		let accessEnabled = AXIsProcessTrustedWithOptions(options)

		if accessEnabled {
			logger.info("Accessibility permissions granted, setting up shortcut")
			setupShortcut()
		} else {
			logger.info("Waiting for accessibility permissions...")
			logger.info(
				"Please go to System Settings > Privacy & Security > Accessibility and enable Whispera")
			logger.info("Global shortcuts will NOT work until accessibility permissions are granted")

			// Check again every 3 seconds for up to 30 seconds
			var checkCount = 0
			let maxChecks = 10

			func checkPermissions() {
				checkCount += 1
				if AXIsProcessTrusted() {
					self.logger.info(
						"Accessibility permissions now granted! Setting up global shortcuts...")
					self.setupShortcut()
				} else if checkCount < maxChecks {
					self.logger.info(
						"Still waiting for accessibility permissions... (\(checkCount)/\(maxChecks))")
					DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
						checkPermissions()
					}
				} else {
					self.logger.error(
						"Accessibility permissions still not granted. Global shortcuts disabled.")
					self.logger.error(
						"You can grant permissions later in System Settings > Privacy & Security > Accessibility"
					)
				}
			}

			DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
				checkPermissions()
			}
		}
	}

	private func handleTextHotKey() {
		Task { @MainActor in
			// Check if haptic feedback is enabled
			if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
				NSHapticFeedbackManager.defaultPerformer
					.perform(.levelChange, performanceTime: .now)
			}
			audioManager?.toggleRecording()
		}
	}

	private func handleFileSelectionHotKey() {
		Task { @MainActor in
			logger.info("File selection shortcut activated")

			// Prevent duplicate processing
			guard !isProcessingFileOperation else {
				logger.info("File operation already in progress, ignoring shortcut")
				return
			}

			isProcessingFileOperation = true
			defer { isProcessingFileOperation = false }

			// Check if haptic feedback is enabled
			if UserDefaults.standard.bool(forKey: "shortcutHapticFeedback") {
				NSHapticFeedbackManager.defaultPerformer
					.perform(.levelChange, performanceTime: .now)
			}

			// First, try to get selected files from Finder
			let finderSelection = await getFinderSelectedFiles()
			if !finderSelection.isEmpty {
				logger.info("Found \(finderSelection.count) selected files in Finder")
				await handleSelectedFiles(finderSelection)
				return
			}

			// Check if there's a URL in the clipboard
			let pasteboard = NSPasteboard.general
			if let clipboardString = pasteboard.string(forType: .string),
				let url = URL(string: clipboardString),
				url.scheme == "http" || url.scheme == "https"
			{
				logger.info("Found URL in clipboard: \(clipboardString)")
				await handleClipboardURL(url)
			} else {
				// Open file selection dialog as fallback
				await openFileSelectionDialog()
			}
		}
	}

	private func getFinderSelectedFiles() async -> [URL] {
		let script = """
			tell application "Finder"
			    set selectedItems to selection
			    set filePaths to {}
			    repeat with selectedItem in selectedItems
			        if class of selectedItem is document file then
			            set end of filePaths to POSIX path of (selectedItem as alias)
			        end if
			    end repeat
			    return filePaths
			end tell
			"""

		let appleScript = NSAppleScript(source: script)
		var error: NSDictionary?
		let result = appleScript?.executeAndReturnError(&error)

		if let error = error {
			let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
			switch errorCode {
			case -1751:
				logger.info("AppleScript: User canceled or no files selected in Finder")
			case -1743:
				logger.error("AppleScript: Finder is not running or accessible")
			case -1700:
				logger.error("AppleScript: Access denied to Finder")
			default:
				logger.error("AppleScript error: \(error)")
			}
			return []
		}

		if let result = result {
			// Handle the result - it might be a list or a single value
			let paths = extractPathsFromAppleScriptResult(result)
			let urls = paths.compactMap { path -> URL? in
				return URL(fileURLWithPath: path)
			}
			return urls.filter { url in
				let fileExtension = url.pathExtension.lowercased()
				return SupportedFileTypes.allFormats.contains(fileExtension)
			}
		}

		return []
	}

	private func extractPathsFromAppleScriptResult(_ result: NSAppleEventDescriptor) -> [String] {
		var paths: [String] = []

		// Check if it's a list
		if result.descriptorType == typeAEList {
			let listSize = result.numberOfItems
			// Guard against empty lists to avoid Range error
			guard listSize > 0 else { return paths }

			for i in 1...listSize {
				if let item = result.atIndex(i),
					let path = item.stringValue
				{
					paths.append(path)
				}
			}
		} else if let singlePath = result.stringValue {
			// Single item
			paths.append(singlePath)
		}

		return paths
	}

	@MainActor
	private func handleSelectedFiles(_ urls: [URL]) async {
		logger.info("Adding \(urls.count) selected audio files to transcription queue")

		guard let queueManager = queueManager else {
			logger.error("TranscriptionQueueManager not available, falling back to direct processing")
			await handleSelectedFilesDirectly(urls)
			return
		}

		// Add all files to the queue
		queueManager.addFiles(urls)
		logger.info("Added \(urls.count) files to transcription queue")

		// Show a notification that files were added to queue
		let notification = NSUserNotification()
		notification.title = "Files Added to Queue"
		notification.subtitle = "\(urls.count) file(s) queued for transcription"
		notification.informativeText = urls.map { $0.lastPathComponent }.joined(separator: ", ")
		NSUserNotificationCenter.default.deliver(notification)
	}

	@MainActor
	private func handleSelectedFilesDirectly(_ urls: [URL]) async {
		logger.info("Processing \(urls.count) selected audio files directly")

		guard let fileManager = fileTranscriptionManager else {
			logger.error("FileTranscriptionManager not available")
			return
		}

		// For now, we'll process the first file (can be enhanced for multiple files)
		guard let firstFile = urls.first else { return }

		do {
			logger.info("Starting transcription for: \(firstFile.lastPathComponent)")

			let result = try await fileManager.transcribeFile(at: firstFile)

			// Show the result in a notification or window
			await showTranscriptionResult(for: firstFile.lastPathComponent, result: result)

		} catch {
			logger.error("Transcription failed: \(error)")
			showTranscriptionError(error)
		}
	}

	@MainActor
	private func showTranscriptionResult(for filename: String, result: String) async {
		// Create a simple notification for now
		let notification = NSUserNotification()
		notification.title = "Transcription Complete"
		notification.subtitle = filename
		notification.informativeText = String(result.prefix(100)) + (result.count > 100 ? "..." : "")

		NSUserNotificationCenter.default.deliver(notification)

		// Also copy to clipboard
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(result, forType: .string)

		// Save to file
		await saveTranscriptionToFile(result, originalFilename: filename)
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
			logger.info("Transcription saved to: \(fileURL.path)")
		} catch {
			logger.error("Failed to save transcription to file: \(error.localizedDescription)")
		}
	}

	@MainActor
	private func showTranscriptionError(_ error: Error) {
		let notification = NSUserNotification()
		notification.title = "Transcription Failed"
		notification.informativeText = error.localizedDescription

		NSUserNotificationCenter.default.deliver(notification)
	}

	@MainActor
	private func openFileSelectionDialog() async {
		logger.info("Opening file selection dialog")
		let openPanel = NSOpenPanel()
		openPanel.title = "Select Audio or Video Files to Transcribe"
		openPanel.message = "Choose audio or video files for transcription"
		openPanel.allowsMultipleSelection = true
		openPanel.canChooseDirectories = false
		openPanel.canChooseFiles = true

		openPanel.allowedContentTypes = [
			.audio,
			.video,
			.mp3,
			.mpeg4Audio,
			.wav,
			.aiff,
			.movie,
			.quickTimeMovie,
			.avi,
		]

		let response = openPanel.runModal()

		if response == .OK {
			let selectedURLs = openPanel.urls
			logger.info(
				"Selected \(selectedURLs.count) file(s): \(selectedURLs.map { $0.lastPathComponent })")

			guard let queueManager = queueManager else {
				logger.error("TranscriptionQueueManager not available, falling back to direct processing")
				await processFilesDirectly(selectedURLs)
				return
			}

			// Add files to queue
			queueManager.addFiles(selectedURLs)
			logger.info("Added \(selectedURLs.count) files to transcription queue")

			// Show notification
			let notification = NSUserNotification()
			notification.title = "Files Added to Queue"
			notification.subtitle = "\(selectedURLs.count) file(s) queued for transcription"
			notification.informativeText = selectedURLs.map { $0.lastPathComponent }.joined(
				separator: ", ")
			NSUserNotificationCenter.default.deliver(notification)
		} else {
			logger.info("File selection cancelled")
		}
	}

	@MainActor
	private func processFilesDirectly(_ urls: [URL]) async {
		guard let fileManager = fileTranscriptionManager else {
			logger.error("FileTranscriptionManager not available")
			return
		}

		// Transcribe selected files directly
		do {
			if urls.count == 1 {
				let result = try await fileManager.transcribeFile(at: urls[0])
				logger.info("Transcription completed: \(result.prefix(100))...")

				// Copy result to clipboard
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				pasteboard.setString(result, forType: .string)
				logger.info("Result copied to clipboard")
			} else {
				let results = try await fileManager.transcribeFiles(at: urls)
				let combinedResult = results.enumerated().map { index, result in
					"File \(index + 1) (\(urls[index].lastPathComponent)):\n\(result)"
				}.joined(separator: "\n\n")

				logger.info("Batch transcription completed")

				// Copy combined results to clipboard
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				pasteboard.setString(combinedResult, forType: .string)
				logger.info("Combined results copied to clipboard")
			}
		} catch {
			logger.error("Transcription failed: \(error.localizedDescription)")
		}
	}

	@MainActor
	private func handleClipboardURL(_ url: URL) async {
		logger.info("Adding clipboard URL to transcription queue: \(url.absoluteString)")

		guard let queueManager = queueManager else {
			logger.error("TranscriptionQueueManager not available, falling back to direct processing")
			await handleClipboardURLDirectly(url)
			return
		}

		// Add URL to queue
		queueManager.addFile(url)
		logger.info("Added URL to transcription queue")

		// Show notification
		let notification = NSUserNotification()
		notification.title = "URL Added to Queue"
		notification.subtitle = "Network file queued for transcription"
		notification.informativeText = url.absoluteString
		NSUserNotificationCenter.default.deliver(notification)
	}

	private func handleClipboardURLDirectly(_ url: URL) async {
		logger.info("Processing clipboard URL directly: \(url.absoluteString)")

		guard let fileManager = fileTranscriptionManager,
			let downloader = networkDownloader
		else {
			logger.error("FileTranscriptionManager or NetworkFileDownloader not available")
			return
		}

		do {
			// Check if it's a YouTube URL
			if isYouTubeURL(url) {
				logger.info("Detected YouTube URL, using YouTube transcription manager")
				let youtubeManager = await YouTubeTranscriptionManager(
					fileTranscriptionManager: fileManager,
					networkDownloader: downloader
				)
				let result = try await youtubeManager.transcribeYouTubeURL(url)

				// Show the result
				await showTranscriptionResult(for: "YouTube Video", result: result)

			} else {
				// Handle as regular network file
				let result: String =
					try await downloader.downloadAndTranscribe(
						from: url,
						using: fileManager,
						withTimestamps: false,
						deleteAfterTranscription: autoDeleteDownloadedFiles
					) as! String

				let filename = url.lastPathComponent.isEmpty ? "Network File" : url.lastPathComponent
				await showTranscriptionResult(for: filename, result: result)
			}

			logger.info("URL transcription completed")

		} catch {
			logger.error("URL transcription failed: \(error.localizedDescription)")
			await showTranscriptionError(error)
		}
	}

	private func isYouTubeURL(_ url: URL) -> Bool {
		let host = url.host?.lowercased()
		return host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be"
			|| host == "m.youtube.com"
	}

	deinit {
		if let monitor = globalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = localMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = fileSelectionGlobalMonitor {
			NSEvent.removeMonitor(monitor)
		}
		if let monitor = fileSelectionLocalMonitor {
			NSEvent.removeMonitor(monitor)
		}
	}
}
