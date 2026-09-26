import AppKit
import Foundation
import Testing

@testable import Whispera

struct RemoteCommandParsingTests {

	@Test(arguments: [
		("whispera://toggle", RemoteCommand.toggle),
		("whispera://toggle-post-process", .togglePostProcess),
		("whispera://start", .start),
		("whispera://stop", .stop),
		("whispera://cancel", .cancel),
		("WHISPERA://Toggle", .toggle),
		("whispera:toggle", .toggle),
		("whispera:///cancel", .cancel),
		("whispera://language?name=German", .setLanguage("German")),
		("whispera://language?code=de", .setLanguage("de")),
		("whispera://model?name=openai_whisper-tiny.en", .setModel("openai_whisper-tiny.en")),
	])
	func parsesKnownCommands(urlString: String, expected: RemoteCommand) throws {
		let url = try #require(URL(string: urlString))
		#expect(RemoteCommand(url: url) == expected)
	}

	@Test(arguments: [
		"https://toggle",
		"whispera://",
		"whispera://record",
		"whispera://language",
		"whispera://language?name=%20",
		"whispera://model",
	])
	func rejectsUnknownOrIncompleteURLs(urlString: String) throws {
		let url = try #require(URL(string: urlString))
		#expect(RemoteCommand(url: url) == nil)
	}

	@Test(arguments: [
		RemoteCommand.toggle, .togglePostProcess, .start, .stop, .cancel, .setLanguage("french"),
		.setModel("openai_whisper-base.en"),
	])
	func urlRoundTrips(command: RemoteCommand) {
		#expect(RemoteCommand(url: command.url) == command)
	}

	@Test func resolvesLanguageByNameOrCode() {
		#expect(RemoteCommand.resolveLanguageName("German") == "german")
		#expect(RemoteCommand.resolveLanguageName("de") == "german")
		#expect(RemoteCommand.resolveLanguageName(" EN ") == "english")
		#expect(RemoteCommand.resolveLanguageName("klingon") == nil)
		#expect(RemoteCommand.resolveLanguageName("") == nil)
		#expect(RemoteCommand.resolveLanguageName(" AUTO ") == Constants.autoDetectLanguageName)
	}

	@Test func urlSchemeDefaultsToDisabledAndHonorsOptIn() throws {
		let suite = "RemoteControlSettingsTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(!RemoteControlSettings.isURLSchemeEnabled(in: defaults))
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)
		#expect(RemoteControlSettings.isURLSchemeEnabled(in: defaults))
	}

	@Test func onlyMicModelAndHistoryCommandsRequireAToken() {
		#expect(RemoteCommand.copyLastTranscript.requiresToken)
		#expect(RemoteCommand.openHistory.requiresToken)
		#expect(RemoteCommand.addWord("Loki").requiresToken)
		#expect(RemoteCommand.toggle.requiresToken)
		#expect(RemoteCommand.togglePostProcess.requiresToken)
		#expect(RemoteCommand.start.requiresToken)
		#expect(RemoteCommand.setModel("x").requiresToken)
		#expect(!RemoteCommand.stop.requiresToken)
		#expect(!RemoteCommand.cancel.requiresToken)
		#expect(RemoteCommand.setLanguage("de").requiresToken)
		#expect(RemoteCommand.stop.isAlwaysAllowedFromURL)
		#expect(RemoteCommand.cancel.isAlwaysAllowedFromURL)
		#expect(!RemoteCommand.setLanguage("de").isAlwaysAllowedFromURL)
	}

	@Test func tokenIsAddedOnlyToCommandsThatNeedItAndDoesNotChangeParsing() throws {
		let token = String(repeating: "ab", count: 32)
		let start = RemoteCommand.start.url(token: token)
		#expect(RemoteCommand.token(in: start) == token)
		#expect(RemoteCommand(url: start) == .start)
		let model = RemoteCommand.setModel("openai_whisper-tiny.en").url(token: token)
		#expect(RemoteCommand(url: model) == .setModel("openai_whisper-tiny.en"))
		#expect(RemoteCommand.token(in: model) == token)
		#expect(RemoteCommand.token(in: RemoteCommand.stop.url(token: token)) == nil)
	}
}

struct RemoteControlTokenTests {
	private func makeDirectory() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("rc-token-\(UUID().uuidString)")
	}

	@Test func createsAUserOnlyTokenOnceAndReusesIt() throws {
		let directory = makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(RemoteControlToken.load(in: directory, createIfMissing: false) == nil)
		let token = try #require(RemoteControlToken.load(in: directory))
		#expect(RemoteControlToken.isWellFormed(token))
		#expect(RemoteControlToken.load(in: directory) == token)

		let attributes = try FileManager.default.attributesOfItem(
			atPath: RemoteControlToken.fileURL(in: directory).path)
		let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
		#expect(permissions & 0o077 == 0, "token file must not be readable by other users")
	}

	@Test func regenerateInvalidatesTheOldToken() throws {
		let directory = makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let first = try #require(RemoteControlToken.load(in: directory))
		let second = try RemoteControlToken.regenerate(in: directory)
		#expect(first != second)
		#expect(RemoteControlToken.load(in: directory) == second)
	}

	@Test func matchingRejectsMissingWrongAndMalformedTokens() {
		let token = String(repeating: "0f", count: 32)
		#expect(RemoteControlToken.matches(token, expected: token))
		#expect(!RemoteControlToken.matches(nil, expected: token))
		#expect(!RemoteControlToken.matches("", expected: token))
		#expect(!RemoteControlToken.matches(String(repeating: "0e", count: 32), expected: token))
		#expect(!RemoteControlToken.matches(token, expected: nil))
		#expect(!RemoteControlToken.matches("", expected: ""))
	}
}

@MainActor
final class FakeDictationController: DictationControlling {
	var isRecording = false
	var isMicrophoneInitializing = false
	var isTranscribing = false
	var toggles = 0
	var postProcessToggles = 0
	var stops = 0
	var cancels = 0

	func toggleRecording(postProcess: Bool) {
		toggles += 1
		if postProcess { postProcessToggles += 1 }
		isRecording.toggle()
	}

	func requestStop() {
		stops += 1
		isRecording = false
		isMicrophoneInitializing = false
	}

	func cancelRecording() {
		cancels += 1
		isRecording = false
		isTranscribing = false
	}
}

@MainActor
final class FakeModelSwitcher: ModelSwitching {
	var downloaded: Set<String>
	var switchedTo: [String] = []

	init(downloaded: Set<String>) {
		self.downloaded = downloaded
	}

	func downloadedModelNames() async -> Set<String> { downloaded }

	func switchModel(to model: String) async throws {
		switchedTo.append(model)
	}
}

@MainActor
struct RemoteControlCenterTests {
	@Test func togglePostProcessAsksForPostProcessing() async throws {
		let suite = "RemoteControlCenterTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let center = RemoteControlCenter(defaults: defaults)
		let controller = FakeDictationController()
		center.register(controller: controller)

		#expect(await center.handle(.togglePostProcess, source: .url) == .performed)
		#expect(controller.isRecording)
		#expect(controller.postProcessToggles == 1)
		#expect(await center.handle(.toggle, source: .url) == .performed)
		#expect(controller.postProcessToggles == 1)
	}

	private func makeCenter() throws -> (RemoteControlCenter, UserDefaults, String) {
		let suite = "RemoteControlCenterTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		let tokenDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
		return (RemoteControlCenter(defaults: defaults, tokenDirectory: tokenDirectory), defaults, suite)
	}

	private func tokenDirectory(for suite: String) -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent(suite)
	}

	@Test func startAndStopAreIdempotent() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		center.register(controller: controller)

		#expect(await center.handle(.stop, source: .url) == .ignored("Not recording"))
		#expect(await center.handle(.start, source: .url) == .performed)
		#expect(await center.handle(.start, source: .url) == .ignored("Already recording"))
		#expect(controller.isRecording)
		#expect(await center.handle(.stop, source: .intent) == .performed)
		#expect(!controller.isRecording)
		#expect(controller.toggles == 1)
		#expect(controller.stops == 1)
	}

	@Test func stopDuringMicrophoneStartupIsForwardedForDeferral() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		controller.isMicrophoneInitializing = true
		center.register(controller: controller)

		#expect(await center.handle(.stop, source: .url) == .performed)
		#expect(controller.stops == 1)
		#expect(controller.toggles == 0)
	}

	@Test func cancelReachesATranscriptionInFlight() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		controller.isTranscribing = true
		center.register(controller: controller)

		#expect(await center.handle(.cancel, source: .cli) == .performed)
		#expect(controller.cancels == 1)
		#expect(await center.handle(.stop, source: .cli) == .ignored("Not recording"))
	}

	@Test func startIsIgnoredWhileMicrophoneInitializes() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		controller.isMicrophoneInitializing = true
		center.register(controller: controller)

		#expect(await center.handle(.start, source: .url) == .ignored("Already recording"))
		#expect(await center.handle(.cancel, source: .url) == .performed)
		#expect(controller.cancels == 1)
		#expect(controller.toggles == 0)
	}

	@Test func cancelOnlyActsWhileRecording() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		center.register(controller: controller)

		#expect(await center.handle(.cancel, source: .cli) == .ignored("Not recording"))
		#expect(await center.handle(.toggle, source: .cli) == .performed)
		#expect(await center.handle(.cancel, source: .cli) == .performed)
		#expect(controller.cancels == 1)
		#expect(!controller.isRecording)
	}

	@Test func commandBeforeLaunchRunsOnceControllerRegisters() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(await center.handle(.toggle, source: .url) == .deferred)
		let controller = FakeDictationController()
		center.register(controller: controller)
		#expect(controller.toggles == 1)
		#expect(controller.isRecording)
	}

	@Test func languageCommandWritesCanonicalNameAndDisablesKeyboardDetection() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(true, forKey: "autoDetectLanguageFromKeyboard")

		#expect(await center.handle(.setLanguage("de"), source: .url) == .performed)
		#expect(defaults.string(forKey: "selectedLanguage") == "german")
		#expect(defaults.bool(forKey: "autoDetectLanguageFromKeyboard") == false)

		let rejected = await center.handle(.setLanguage("klingon"), source: .url)
		#expect(rejected == .rejected("Unknown language: klingon"))
		#expect(defaults.string(forKey: "selectedLanguage") == "german")

		#expect(await center.handle(.setLanguage("Auto"), source: .url) == .performed)
		#expect(defaults.string(forKey: "selectedLanguage") == Constants.autoDetectLanguageName)
	}

	@Test func modelCommandOnlySwitchesToDownloadedModels() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let switcher = FakeModelSwitcher(downloaded: ["openai_whisper-tiny.en"])
		center.register(controller: FakeDictationController(), modelSwitcher: switcher)

		#expect(await center.handle(.setModel("openai_whisper-tiny.en"), source: .url) == .performed)
		let outcome = await center.handle(.setModel("openai_whisper-large-v3"), source: .url)
		guard case .rejected = outcome else {
			Issue.record("Expected rejection for a model that is not downloaded, got \(outcome)")
			return
		}
		#expect(switcher.switchedTo == ["openai_whisper-tiny.en"])
	}

	@Test func freshInstallIgnoresMicLinksEvenWithAValidToken() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer {
			defaults.removePersistentDomain(forName: suite)
			try? FileManager.default.removeItem(at: tokenDirectory(for: suite))
		}
		let controller = FakeDictationController()
		center.register(controller: controller)
		let token = try #require(RemoteControlToken.load(in: tokenDirectory(for: suite)))

		#expect(center.handleURL(RemoteCommand.toggle.url) == false)
		#expect(center.handleURL(RemoteCommand.start.url(token: token)) == false)
		#expect(center.handleURL(RemoteCommand.setLanguage("de").url) == false)
		#expect(center.handleURL(RemoteCommand.setModel("m").url(token: token)) == false)
		try await Task.sleep(nanoseconds: 50_000_000)
		#expect(controller.toggles == 0)
		#expect(defaults.string(forKey: "selectedLanguage") == nil)
	}

	@Test func stopAndCancelLinksWorkEvenWhenURLControlIsOff() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		controller.isRecording = true
		center.register(controller: controller)

		#expect(center.authorizeURL(.stop, url: RemoteCommand.stop.url) == .allowed)
		#expect(center.authorizeURL(.cancel, url: RemoteCommand.cancel.url) == .allowed)
		#expect(center.handleURL(RemoteCommand.cancel.url))
		for _ in 0..<50 where controller.cancels == 0 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		#expect(controller.cancels == 1)
	}

	@Test func enabledURLControlStillRejectsMicLinksWithoutTheToken() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer {
			defaults.removePersistentDomain(forName: suite)
			try? FileManager.default.removeItem(at: tokenDirectory(for: suite))
		}
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)
		let token = try #require(RemoteControlToken.load(in: tokenDirectory(for: suite)))
		let wrong = String(repeating: "a", count: 64)

		for command in [
			RemoteCommand.toggle, .togglePostProcess, .start, .setModel("m"), .copyLastTranscript, .openHistory,
			.addWord("Loki"), .setLanguage("de"),
		] {
			#expect(center.authorizeURL(command, url: command.url) == .denied("missing or invalid token"))
			#expect(center.authorizeURL(command, url: command.url(token: wrong)) != .allowed)
			#expect(center.authorizeURL(command, url: command.url(token: token)) == .allowed)
		}
	}

	@Test func micLinksAreRejectedWhenNoTokenExistsYet() throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)

		let guess = RemoteCommand.start.url(token: String(repeating: "0", count: 64))
		#expect(center.authorizeURL(.start, url: guess) != .allowed)
		#expect(!FileManager.default.fileExists(atPath: tokenDirectory(for: suite).path))
	}

	@Test func enabledURLSchemeDispatchesTokenLinks() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer {
			defaults.removePersistentDomain(forName: suite)
			try? FileManager.default.removeItem(at: tokenDirectory(for: suite))
		}
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)
		let token = try #require(RemoteControlToken.load(in: tokenDirectory(for: suite)))
		let controller = FakeDictationController()
		center.register(controller: controller)

		#expect(center.handleURL(RemoteCommand.toggle.url(token: token)))
		#expect(center.handleURL(URL(string: "whispera://bogus")!) == false)
		for _ in 0..<50 where controller.toggles == 0 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		#expect(controller.toggles == 1)
	}
}

struct TranscribeIntentFileNameTests {
	@Test(arguments: [
		("talk.m4a", "talk.m4a"),
		("../../etc/passwd", "passwd"),
		("/abs/path/clip.wav", "clip.wav"),
		("", "shortcut-audio"),
		("..", "shortcut-audio"),
		("/", "shortcut-audio"),
		("   ", "shortcut-audio"),
	])
	func keepsOnlyTheLastPathComponent(raw: String, expected: String) {
		#expect(TranscribeAudioFileIntent.safeFileName(raw) == expected)
	}
}

struct RemoteHistoryCommandParsingTests {
	@Test(arguments: [
		("whispera://copy-last", RemoteCommand.copyLastTranscript),
		("whispera://history", .openHistory),
		("whispera://add-word?word=Kubernetes", .addWord("Kubernetes")),
		("whispera://add-word?word=Grafana%2C%20Loki", .addWord("Grafana, Loki")),
		("whispera://add-word?name=Tailscale", .addWord("Tailscale")),
	])
	func parses(urlString: String, expected: RemoteCommand) throws {
		#expect(RemoteCommand(url: try #require(URL(string: urlString))) == expected)
	}

	@Test func addWordNeedsAWord() throws {
		#expect(RemoteCommand(url: try #require(URL(string: "whispera://add-word"))) == nil)
		#expect(RemoteCommand(url: try #require(URL(string: "whispera://add-word?word=%20"))) == nil)
	}

	@Test(arguments: [RemoteCommand.copyLastTranscript, .openHistory, .addWord("São Paulo & Co")])
	func roundTrips(command: RemoteCommand) {
		#expect(RemoteCommand(url: command.url) == command)
	}

	@Test func wordListLimits() {
		#expect(RemoteCommand.parseWords(" Kubernetes ,  kubernetes, Loki ") == ["Kubernetes", "Loki"])
		#expect(RemoteCommand.parseWords(" , ") == nil)
		#expect(RemoteCommand.parseWords(String(repeating: "a", count: RemoteCommand.maxWordLength + 1)) == nil)
		let many = (0...RemoteCommand.maxWordsPerCommand).map { "w\($0)" }.joined(separator: ",")
		#expect(RemoteCommand.parseWords(many) == nil)
	}

	@Test func cliFlagsMapToCommands() throws {
		#expect(try CLIOptions.parse(["--copy-last"]).action == .remote(.copyLastTranscript))
		#expect(try CLIOptions.parse(["--open-history"]).action == .remote(.openHistory))
		#expect(try CLIOptions.parse(["--add-word=Loki"]).action == .remote(.addWord("Loki")))
		#expect(throws: CLIOptions.ParseError.self) { try CLIOptions.parse(["--add-word"]) }
		#expect(CLIOptions.isCLIInvocation(["Whispera", "--copy-last"]))
	}
}

@MainActor
private final class HistoryActionLog {
	var lastTranscript: String?
	var copied: [String] = []
	var historyOpens = 0

	var actions: RemoteHistoryActions {
		RemoteHistoryActions(
			lastTranscript: { _ in self.lastTranscript },
			copyToClipboard: { self.copied.append($0) },
			openHistory: { self.historyOpens += 1 })
	}
}

@MainActor
struct RemoteHistoryCommandTests {
	private func makeCenter(_ log: HistoryActionLog) throws -> (RemoteControlCenter, UserDefaults, String) {
		let suite = "RemoteHistoryCommandTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		return (RemoteControlCenter(defaults: defaults, historyActions: log.actions), defaults, suite)
	}

	@Test func copyLastCopiesTheLatestTranscript() async throws {
		let log = HistoryActionLog()
		let (center, defaults, suite) = try makeCenter(log)
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(await center.handle(.copyLastTranscript, source: .url) == .ignored("No transcript yet"))
		#expect(log.copied.isEmpty)

		log.lastTranscript = "Ship it on Friday."
		#expect(await center.handle(.copyLastTranscript, source: .url) == .performed)
		#expect(log.copied == ["Ship it on Friday."])
	}

	@Test func openHistoryOpensTheWindowWithoutAController() async throws {
		let log = HistoryActionLog()
		let (center, defaults, suite) = try makeCenter(log)
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(await center.handle(.openHistory, source: .intent) == .performed)
		#expect(log.historyOpens == 1)
	}

	@Test func addWordAppendsNewWordsOnly() async throws {
		let (center, defaults, suite) = try makeCenter(HistoryActionLog())
		defer { defaults.removePersistentDomain(forName: suite) }
		TextProcessingSettings.setCustomWords(["Kubernetes"], in: defaults)

		#expect(await center.handle(.addWord("kubernetes, Grafana"), source: .cli) == .performed)
		#expect(TextProcessingSettings.customWords(from: defaults) == ["Kubernetes", "Grafana"])

		#expect(await center.handle(.addWord("GRAFANA"), source: .cli) == .ignored("Already in the dictionary"))
		#expect(TextProcessingSettings.customWords(from: defaults) == ["Kubernetes", "Grafana"])
	}

	@Test func addWordRejectsOversizedInput() async throws {
		let (center, defaults, suite) = try makeCenter(HistoryActionLog())
		defer { defaults.removePersistentDomain(forName: suite) }
		let outcome = await center.handle(
			.addWord(String(repeating: "x", count: RemoteCommand.maxWordLength + 1)), source: .url)
		guard case .rejected = outcome else {
			Issue.record("Expected rejection, got \(outcome)")
			return
		}
		#expect(TextProcessingSettings.customWords(from: defaults).isEmpty)
	}

	@Test func historyCommandsAreNotDictationCommands() async throws {
		let (center, defaults, suite) = try makeCenter(HistoryActionLog())
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		center.register(controller: controller)
		#expect(await center.handle(.openHistory, source: .url) == .performed)
		#expect(controller.toggles == 0)
	}
}

@MainActor
struct RemoteControlHardeningTests {
	@Test func copyLastReturnsWhatItCopiedNotTheClipboard() throws {
		let log = HistoryActionLog()
		let suite = "RemoteControlHardeningTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let center = RemoteControlCenter(defaults: defaults, historyActions: log.actions)

		#expect(center.copyLastTranscriptText() == nil)
		log.lastTranscript = "Ship it on Friday."
		#expect(center.copyLastTranscriptText() == "Ship it on Friday.")
		#expect(log.copied == ["Ship it on Friday."])
	}

	@Test func linkArgumentsCannotForgeLogLines() {
		let forged = "de\n2026-01-01 [General] Remote command toggle from url"
		let description = RemoteCommand.setLanguage(forged).logDescription
		#expect(!description.contains("\n"))
		#expect(!description.contains("\r"))
		#expect(!description.contains("["))
		#expect(RemoteCommand.sanitizedForLog("openai_whisper-small.en") == "openai_whisper-small.en")
		#expect(RemoteCommand.sanitizedForLog(String(repeating: "a", count: 200)).count <= 51)
		#expect(!RemoteCommand.setModel("m\r\nx").logDescription.contains("\r"))
	}

	@Test func rejectedLanguageMessageIsSanitized() async throws {
		let suite = "RemoteControlHardeningTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let center = RemoteControlCenter(defaults: defaults, historyActions: HistoryActionLog().actions)

		let outcome = await center.handle(.setLanguage("x\nforged line"), source: .url)
		#expect(outcome == .rejected("Unknown language: x?forged line"))
	}
}

struct AutomationSettingsTokenTests {
	@Test func settingsRowsNeverShowTheToken() {
		let token = String(repeating: "c3", count: 32)
		let command = RemoteCommand.start.url(token: token).absoluteString
		let shown = AutomationSettingsView.maskingToken(in: command, token: token)
		#expect(!shown.contains(token))
		#expect(shown.hasPrefix("whispera://start?token="))
		#expect(AutomationSettingsView.maskingToken(in: "whispera://stop", token: token) == "whispera://stop")
		#expect(AutomationSettingsView.maskingToken(in: command, token: nil) == command)
	}

	@MainActor
	@Test func secretCopiesAreConcealed() {
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("whispera.token.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		ClipboardWriter.write("whispera://start?token=abc", to: pasteboard, transient: true, concealed: true)
		let types = pasteboard.pasteboardItems?.first?.types ?? []
		#expect(types.contains(ClipboardWriter.concealedType))
		#expect(types.contains(ClipboardWriter.transientType))
	}
}

struct AppIntentAuthenticationTests {
	@Test func intentsThatOpenTheMicOrReturnTextRequireAnUnlockedMac() {
		for policy in [
			ToggleDictationIntent.authenticationPolicy, StartDictationIntent.authenticationPolicy,
			CopyLastTranscriptIntent.authenticationPolicy,
		] {
			#expect(String(describing: policy).contains("requiresAuthentication"), "\(policy)")
		}
	}
}
