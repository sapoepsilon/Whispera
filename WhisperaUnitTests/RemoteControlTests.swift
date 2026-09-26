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
	}

	@Test func urlSchemeDefaultsToEnabledAndHonorsOptOut() throws {
		let suite = "RemoteControlSettingsTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(RemoteControlSettings.isURLSchemeEnabled(in: defaults))
		defaults.set(false, forKey: RemoteControlSettings.urlSchemeEnabledKey)
		#expect(!RemoteControlSettings.isURLSchemeEnabled(in: defaults))
	}
}

@MainActor
final class FakeDictationController: DictationControlling {
	var isRecording = false
	var isMicrophoneInitializing = false
	var toggles = 0
	var postProcessToggles = 0
	var cancels = 0

	func toggleRecording(postProcess: Bool) {
		toggles += 1
		if postProcess { postProcessToggles += 1 }
		isRecording.toggle()
	}

	func cancelRecording() {
		cancels += 1
		isRecording = false
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
		return (RemoteControlCenter(defaults: defaults), defaults, suite)
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
		#expect(controller.toggles == 2)
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

	@Test func disabledURLSchemeIgnoresLinks() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		center.register(controller: controller)
		defaults.set(false, forKey: RemoteControlSettings.urlSchemeEnabledKey)

		#expect(center.handleURL(RemoteCommand.toggle.url) == false)
		#expect(controller.toggles == 0)
	}

	@Test func enabledURLSchemeDispatchesLinks() async throws {
		let (center, defaults, suite) = try makeCenter()
		defer { defaults.removePersistentDomain(forName: suite) }
		let controller = FakeDictationController()
		center.register(controller: controller)

		#expect(center.handleURL(RemoteCommand.toggle.url))
		#expect(center.handleURL(URL(string: "whispera://bogus")!) == false)
		for _ in 0..<50 where controller.toggles == 0 {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		#expect(controller.toggles == 1)
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
