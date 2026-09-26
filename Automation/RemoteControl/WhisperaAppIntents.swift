import AppIntents
import AppKit
import Foundation

struct RemoteCommandIntentError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

@MainActor
private func runRemoteCommand(_ command: RemoteCommand) async throws -> String {
	let outcome = await RemoteControlCenter.shared.handle(command, source: .intent)
	if case .rejected(let reason) = outcome {
		throw RemoteCommandIntentError(message: reason)
	}
	return outcome.message
}

struct ToggleDictationIntent: AppIntent {
	static var title: LocalizedStringResource = "Toggle Dictation"
	static var description = IntentDescription(
		"Starts dictation, or stops it and inserts the transcript into the focused app.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.toggle))
	}
}

struct StartDictationIntent: AppIntent {
	static var title: LocalizedStringResource = "Start Dictation"
	static var description = IntentDescription("Starts dictation if it is not already running.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.start))
	}
}

struct StopDictationIntent: AppIntent {
	static var title: LocalizedStringResource = "Stop Dictation"
	static var description = IntentDescription(
		"Stops dictation and inserts the transcript into the focused app.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.stop))
	}
}

struct CancelDictationIntent: AppIntent {
	static var title: LocalizedStringResource = "Cancel Dictation"
	static var description = IntentDescription(
		"Stops dictation and discards the recording without transcribing it.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.cancel))
	}
}

struct SetDictationLanguageIntent: AppIntent {
	static var title: LocalizedStringResource = "Set Dictation Language"
	static var description = IntentDescription(
		"Sets the language Whispera transcribes in, by name (German), code (de), or auto to detect it.")
	static var openAppWhenRun = false

	@Parameter(title: "Language")
	var language: String

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.setLanguage(language)))
	}
}

struct CopyLastTranscriptIntent: AppIntent {
	static var title: LocalizedStringResource = "Copy Last Transcript"
	static var description = IntentDescription(
		"Copies the most recent Whispera transcript to the clipboard and returns it.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		let outcome = await RemoteControlCenter.shared.handle(.copyLastTranscript, source: .intent)
		guard outcome == .performed else { throw RemoteCommandIntentError(message: outcome.message) }
		return .result(value: NSPasteboard.general.string(forType: .string) ?? "")
	}
}

struct OpenHistoryIntent: AppIntent {
	static var title: LocalizedStringResource = "Open Transcription History"
	static var description = IntentDescription("Opens the Whispera transcription history window.")
	static var openAppWhenRun = false

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.openHistory))
	}
}

struct AddDictionaryWordIntent: AppIntent {
	static var title: LocalizedStringResource = "Add Word to Dictionary"
	static var description = IntentDescription(
		"Adds a name or term to Whispera's custom words so transcripts spell it your way. Separate several with commas."
	)
	static var openAppWhenRun = false

	@Parameter(title: "Word")
	var word: String

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		.result(value: try await runRemoteCommand(.addWord(word)))
	}
}

struct TranscribeAudioFileIntent: AppIntent {
	static var title: LocalizedStringResource = "Transcribe Audio File"
	static var description = IntentDescription(
		"Transcribes an audio or video file on this Mac with the loaded Whisper model and returns the text."
	)
	static var openAppWhenRun = false

	@Parameter(title: "Audio or Video File")
	var file: IntentFile

	@Parameter(title: "Translate to English", default: false)
	var translate: Bool

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<String> {
		let (url, isTemporary) = try materializedURL()
		defer {
			if isTemporary { try? FileManager.default.removeItem(at: url) }
		}
		AppLogger.shared.general.info("Transcribe intent for \(url.lastPathComponent)")
		let text = try await WhisperKitTranscriber.shared.transcribeFile(
			at: url, enableTranslation: translate)
		return .result(value: text)
	}

	// Shortcuts can hand over in-memory data with no backing file, and WhisperKit reads from disk.
	private func materializedURL() throws -> (URL, Bool) {
		if let fileURL = file.fileURL, FileManager.default.isReadableFile(atPath: fileURL.path) {
			return (fileURL, false)
		}
		let name = Self.safeFileName(file.filename)
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("whispera-intent-\(UUID().uuidString)-\(name)")
		try file.data.write(to: url)
		return (url, true)
	}

	/// Keeps only the last path component so a crafted name cannot point outside the temp folder.
	static func safeFileName(_ raw: String) -> String {
		let last = (raw as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
		let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", trimmed != "/" else { return "shortcut-audio" }
		return String(trimmed.prefix(200))
	}
}

struct WhisperaAppShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: ToggleDictationIntent(),
			phrases: ["Toggle \(.applicationName) dictation", "Dictate with \(.applicationName)"],
			shortTitle: "Toggle Dictation",
			systemImageName: "mic"
		)
		AppShortcut(
			intent: CancelDictationIntent(),
			phrases: ["Cancel \(.applicationName) dictation"],
			shortTitle: "Cancel Dictation",
			systemImageName: "xmark.circle"
		)
		AppShortcut(
			intent: CopyLastTranscriptIntent(),
			phrases: ["Copy the last \(.applicationName) transcript"],
			shortTitle: "Copy Last Transcript",
			systemImageName: "doc.on.clipboard"
		)
		AppShortcut(
			intent: OpenHistoryIntent(),
			phrases: ["Open \(.applicationName) history"],
			shortTitle: "Open History",
			systemImageName: "clock.arrow.circlepath"
		)
		AppShortcut(
			intent: TranscribeAudioFileIntent(),
			phrases: ["Transcribe a file with \(.applicationName)"],
			shortTitle: "Transcribe File",
			systemImageName: "waveform"
		)
	}
}
