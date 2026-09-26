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
