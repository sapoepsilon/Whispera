import AppKit
import Foundation

@MainActor
protocol DictationControlling: AnyObject {
	var isRecording: Bool { get }
	var isMicrophoneInitializing: Bool { get }
	func toggleRecording(postProcess: Bool)
	func cancelRecording()
}

@MainActor
protocol ModelSwitching: AnyObject {
	func downloadedModelNames() async -> Set<String>
	func switchModel(to model: String) async throws
}

enum RemoteCommandOutcome: Equatable, Sendable {
	case performed
	/// Arrived before the app finished launching; it runs once dictation is wired up.
	case deferred
	case ignored(String)
	case rejected(String)

	var message: String {
		switch self {
		case .performed: return "Done"
		case .deferred: return "Queued until Whispera finishes launching"
		case .ignored(let reason): return reason
		case .rejected(let reason): return reason
		}
	}
}

/// History side effects, injectable so tests never touch the real pasteboard or windows.
@MainActor
struct RemoteHistoryActions {
	var lastTranscript: (DictationControlling?) -> String?
	var copyToClipboard: (String) -> Void
	var openHistory: () -> Void

	static let live = RemoteHistoryActions(
		lastTranscript: { controller in
			if let entry = TranscriptionHistoryStore.shared.entries.first(where: {
				!$0.didFail && !$0.text.isEmpty
			}) {
				return entry.text
			}
			// History can be turned off; fall back to the last dictation of this launch.
			guard let audioManager = controller as? AudioManager, audioManager.transcriptionError == nil,
				let text = audioManager.lastTranscription, !text.isEmpty
			else { return nil }
			return text
		},
		copyToClipboard: { text in
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
		},
		openHistory: { HistoryWindowController.shared.show() }
	)
}

/// Single entry point for every external control surface, so the URL scheme, App Intents
/// and the CLI all behave identically.
@MainActor
final class RemoteControlCenter: NSObject {
	static let shared = RemoteControlCenter()

	private weak var controller: DictationControlling?
	private weak var modelSwitcher: ModelSwitching?
	private var pendingCommand: (command: RemoteCommand, source: RemoteCommandSource)?
	private let defaults: UserDefaults
	private let historyActions: RemoteHistoryActions
	private let logger = AppLogger.shared.general

	init(defaults: UserDefaults = .standard, historyActions: RemoteHistoryActions? = nil) {
		self.defaults = defaults
		self.historyActions = historyActions ?? .live
		super.init()
	}

	var hasController: Bool { controller != nil }

	func register(controller: DictationControlling, modelSwitcher: ModelSwitching? = nil) {
		self.controller = controller
		if let modelSwitcher {
			self.modelSwitcher = modelSwitcher
		}
		if let pending = pendingCommand {
			pendingCommand = nil
			logger.info("Running deferred remote command: \(pending.command.logDescription)")
			_ = performDictationCommand(pending.command, source: pending.source)
		}
	}

	@discardableResult
	func handle(_ command: RemoteCommand, source: RemoteCommandSource) async -> RemoteCommandOutcome {
		logger.info("Remote command \(command.logDescription) from \(source.rawValue)")
		let outcome: RemoteCommandOutcome
		switch command {
		case .toggle, .togglePostProcess, .start, .stop, .cancel:
			outcome = performDictationCommand(command, source: source)
		case .setLanguage(let input):
			outcome = applyLanguage(input)
		case .setModel(let model):
			outcome = await applyModel(model)
		case .copyLastTranscript:
			outcome = copyLastTranscript()
		case .openHistory:
			historyActions.openHistory()
			outcome = .performed
		case .addWord(let input):
			outcome = addWords(input)
		}
		if outcome != .performed {
			logger.info("Remote command \(command.logDescription) result: \(outcome.message)")
		}
		return outcome
	}

	/// Returns false when the URL is not a Whispera command or URL control is turned off.
	@discardableResult
	func handleURL(_ url: URL) -> Bool {
		guard RemoteControlSettings.isURLSchemeEnabled(in: defaults) else {
			logger.info("Ignoring whispera:// URL because URL control is disabled in Settings")
			return false
		}
		guard let command = RemoteCommand(url: url) else {
			logger.error("Unrecognized whispera:// URL: \(url.absoluteString)")
			return false
		}
		Task { await handle(command, source: .url) }
		return true
	}

	// SwiftUI's App lifecycle does not reliably forward URL opens to the adaptor delegate
	// when the app has no WindowGroup, so the GetURL Apple Event is claimed directly.
	func installURLHandler() {
		NSAppleEventManager.shared().setEventHandler(
			self,
			andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)
	}

	@objc private func handleGetURLEvent(
		_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
	) {
		guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
			let url = URL(string: string)
		else {
			logger.error("Received a GetURL event without a usable URL")
			return
		}
		handleURL(url)
	}

	private func performDictationCommand(_ command: RemoteCommand, source: RemoteCommandSource)
		-> RemoteCommandOutcome
	{
		guard let controller else {
			pendingCommand = (command, source)
			return .deferred
		}

		let isActive = controller.isRecording || controller.isMicrophoneInitializing
		switch command {
		case .toggle:
			controller.toggleRecording(postProcess: false)
			return .performed
		case .togglePostProcess:
			controller.toggleRecording(postProcess: true)
			return .performed
		case .start:
			guard !isActive else { return .ignored("Already recording") }
			controller.toggleRecording(postProcess: false)
			return .performed
		case .stop:
			guard controller.isRecording else { return .ignored("Not recording") }
			controller.toggleRecording(postProcess: false)
			return .performed
		case .cancel:
			guard isActive else { return .ignored("Not recording") }
			controller.cancelRecording()
			return .performed
		case .setLanguage, .setModel, .copyLastTranscript, .openHistory, .addWord:
			return .rejected("Not a dictation command")
		}
	}

	private func copyLastTranscript() -> RemoteCommandOutcome {
		guard let text = historyActions.lastTranscript(controller) else {
			return .ignored("No transcript yet")
		}
		historyActions.copyToClipboard(text)
		return .performed
	}

	private func addWords(_ input: String) -> RemoteCommandOutcome {
		guard let words = RemoteCommand.parseWords(input) else {
			return .rejected(
				"Give up to \(RemoteCommand.maxWordsPerCommand) comma-separated words of at most \(RemoteCommand.maxWordLength) characters"
			)
		}
		let existing = TextProcessingSettings.customWords(from: defaults)
		let known = Set(existing.map { $0.lowercased() })
		let added = words.filter { !known.contains($0.lowercased()) }
		guard !added.isEmpty else { return .ignored("Already in the dictionary") }
		TextProcessingSettings.setCustomWords(existing + added, in: defaults)
		logger.info("Added \(added.count) word(s) to the custom dictionary")
		return .performed
	}

	private func applyLanguage(_ input: String) -> RemoteCommandOutcome {
		guard let name = RemoteCommand.resolveLanguageName(input) else {
			return .rejected("Unknown language: \(input)")
		}
		defaults.set(false, forKey: "autoDetectLanguageFromKeyboard")
		defaults.set(name, forKey: "selectedLanguage")
		return .performed
	}

	private func applyModel(_ model: String) async -> RemoteCommandOutcome {
		guard let modelSwitcher else {
			return .rejected("Model switching is not available yet")
		}
		let downloaded = await modelSwitcher.downloadedModelNames()
		guard downloaded.contains(model) else {
			return .rejected("Model \(model) is not downloaded. Download it in Settings first.")
		}
		do {
			try await modelSwitcher.switchModel(to: model)
			return .performed
		} catch {
			return .rejected("Could not switch to \(model): \(error.localizedDescription)")
		}
	}
}

extension AudioManager: DictationControlling {}

extension WhisperKitTranscriber: ModelSwitching {
	func downloadedModelNames() async -> Set<String> {
		(try? await getDownloadedModels()) ?? downloadedModels
	}
}
