import AppKit
import Foundation

@MainActor
protocol DictationControlling: AnyObject {
	var isRecording: Bool { get }
	var isMicrophoneInitializing: Bool { get }
	var isTranscribing: Bool { get }
	func toggleRecording(postProcess: Bool)
	func requestStop()
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

/// Single entry point for every external control surface, so the URL scheme, App Intents
/// and the CLI all behave identically.
@MainActor
final class RemoteControlCenter: NSObject {
	static let shared = RemoteControlCenter()

	private weak var controller: DictationControlling?
	private weak var modelSwitcher: ModelSwitching?
	private var pendingCommand: (command: RemoteCommand, source: RemoteCommandSource)?
	private let defaults: UserDefaults
	private let tokenDirectory: URL
	private let logger = AppLogger.shared.general

	init(defaults: UserDefaults = .standard, tokenDirectory: URL = RemoteControlToken.defaultDirectory) {
		self.defaults = defaults
		self.tokenDirectory = tokenDirectory
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
		}
		if outcome != .performed {
			logger.info("Remote command \(command.logDescription) result: \(outcome.message)")
		}
		return outcome
	}

	enum URLAuthorization: Equatable {
		case allowed
		case denied(String)
	}

	/// Stop and cancel are always accepted. Everything else needs URL control turned on, and
	/// commands that can open the mic or swap the model also need the per-install token.
	func authorizeURL(_ command: RemoteCommand, url: URL) -> URLAuthorization {
		if command.isAlwaysAllowedFromURL { return .allowed }
		guard RemoteControlSettings.isURLSchemeEnabled(in: defaults) else {
			return .denied("URL control is disabled in Settings")
		}
		if command.requiresToken {
			let expected = RemoteControlToken.load(in: tokenDirectory, createIfMissing: false)
			guard RemoteControlToken.matches(RemoteCommand.token(in: url), expected: expected) else {
				return .denied("missing or invalid token")
			}
		}
		return .allowed
	}

	/// Returns false when the URL is not a Whispera command or is not authorized.
	@discardableResult
	func handleURL(_ url: URL) -> Bool {
		// Only the verb is logged; the query can carry the token.
		guard let command = RemoteCommand(url: url) else {
			logger.error("Unrecognized whispera:// URL verb: \(url.host ?? url.path)")
			return false
		}
		if case .denied(let reason) = authorizeURL(command, url: url) {
			logger.info("Ignoring whispera://\(command.logDescription): \(reason)")
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
			// A stop during microphone startup is deferred by the controller, like a hotkey release
			guard isActive else { return .ignored("Not recording") }
			controller.requestStop()
			return .performed
		case .cancel:
			// Matches Escape and the pill, which can also abandon a transcription in flight
			guard isActive || controller.isTranscribing else { return .ignored("Not recording") }
			controller.cancelRecording()
			return .performed
		case .setLanguage, .setModel:
			return .rejected("Not a dictation command")
		}
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
