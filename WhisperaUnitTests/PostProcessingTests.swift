import AppKit
import Foundation
import Testing

@testable import Whispera

private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
	let suite = "PostProcessingTests.\(name).\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: suite)!
	defaults.removePersistentDomain(forName: suite)
	return defaults
}

private final class InMemorySecretStore: PostProcessingSecretStore, @unchecked Sendable {
	private let lock = NSLock()
	private var keys: [String: String]

	init(_ keys: [String: String] = [:]) {
		self.keys = keys
	}

	func apiKey(for providerID: String) throws -> String? {
		lock.withLock { keys[providerID] }
	}

	func setAPIKey(_ key: String?, for providerID: String) throws {
		lock.withLock { keys[providerID] = key }
	}
}

private func chatCompletion(_ content: String) -> MockHTTPServer.Response {
	.json([
		"id": "chatcmpl-test",
		"object": "chat.completion",
		"choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
	])
}

// MARK: - Text cleanup

struct PostProcessingTextTests {
	@Test func stripsLeadingThinkBlock() {
		let raw = "  <think>\nthe user said um, I should drop it\n</think>\n\nMeet at 3:30 tomorrow."
		#expect(PostProcessingText.stripLeadingThinkBlock(raw) == "Meet at 3:30 tomorrow.")
	}

	@Test func keepsTextWithoutThinkBlock() {
		#expect(PostProcessingText.stripLeadingThinkBlock("Hello <think>x</think>") == "Hello <think>x</think>")
	}

	@Test func keepsUnterminatedThinkBlock() {
		#expect(PostProcessingText.stripLeadingThinkBlock("<think>never closed") == "<think>never closed")
	}

	@Test func removesZeroWidthCharacters() {
		let raw = "Hi\u{200B} there\u{FEFF}\u{200C}\u{200D}"
		#expect(PostProcessingText.stripInvisibleCharacters(raw) == "Hi there")
	}

	@Test func cleanModelOutputTrims() {
		#expect(PostProcessingText.cleanModelOutput("<think>a</think>  Done.\n") == "Done.")
	}
}

// MARK: - Prompts

struct PostProcessingPromptTests {
	@Test func placeholderTemplateBecomesSingleUserMessage() {
		let prompt = PostProcessingPrompt(id: "p", name: "p", template: "Fix: ${output}!")
		let messages = prompt.messages(for: "hello world")
		#expect(messages == PostProcessingMessages(system: nil, user: "Fix: hello world!"))
	}

	@Test func templateWithoutPlaceholderBecomesInstructions() {
		let prompt = PostProcessingPrompt(id: "p", name: "p", template: "  Make it formal.  ")
		let messages = prompt.messages(for: "hey whats up")
		#expect(messages == PostProcessingMessages(system: "Make it formal.", user: "hey whats up"))
	}

	@Test func emptyTemplateSendsTranscriptOnly() {
		let prompt = PostProcessingPrompt(id: "p", name: "p", template: "   ")
		#expect(prompt.messages(for: "x") == PostProcessingMessages(system: nil, user: "x"))
	}

	@Test func defaultPromptWrapsTranscriptInTags() {
		let user = PostProcessingPrompt.defaultCleanup.messages(for: "um hi").user
		#expect(user.contains("<transcript>\num hi\n</transcript>"))
		#expect(!user.contains(PostProcessingPrompt.outputPlaceholder))
	}
}

// MARK: - Settings

struct PostProcessingSettingsTests {
	@Test func defaults() {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		#expect(settings.isEnabled == false)
		#expect(settings.appliesToEveryDictation == false)
		#expect(settings.shortcut == "⌥⇧Space")
		#expect(settings.providerID == "openai")
		#expect(settings.prompts == [.defaultCleanup])
		#expect(settings.selectedPromptID == PostProcessingPrompt.defaultCleanup.id)
		#expect(settings.timeoutSeconds == 30)
		#expect(settings.model(for: "openai") == "")
	}

	@Test func persistsAcrossInstances() {
		let defaults = isolatedDefaults()
		let writer = PostProcessingSettings(defaults: defaults)
		writer.isEnabled = true
		writer.appliesToEveryDictation = true
		writer.shortcut = "⌃⇧P"
		writer.providerID = "groq"
		writer.setModel("  llama-3.1-8b-instant ", for: "groq")
		let custom = PostProcessingPrompt(id: "formal", name: "Formal", template: "Formal: ${output}")
		writer.prompts = [.defaultCleanup, custom]
		writer.selectedPromptID = "formal"

		let reader = PostProcessingSettings(defaults: defaults)
		#expect(reader.isEnabled)
		#expect(reader.appliesToEveryDictation)
		#expect(reader.shortcut == "⌃⇧P")
		#expect(reader.provider.id == "groq")
		#expect(reader.model(for: "groq") == "llama-3.1-8b-instant")
		#expect(reader.selectedPrompt == custom)
	}

	@Test func unknownProviderFallsBackToDefault() {
		let defaults = isolatedDefaults()
		defaults.set("no_such_provider", forKey: PostProcessingSettings.Key.providerID)
		#expect(PostProcessingSettings(defaults: defaults).provider.id == "openai")
	}

	@Test func missingSelectedPromptFallsBackToFirst() {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.selectedPromptID = "deleted"
		#expect(settings.selectedPrompt == .defaultCleanup)
	}

	@Test func emptyPromptListRestoresDefault() {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.prompts = []
		#expect(settings.prompts == [.defaultCleanup])
	}

	@Test func baseURLOverrideOnlyForEditableProviders() throws {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		let openAI = try #require(PostProcessingProvider.provider(withID: "openai"))
		let custom = try #require(PostProcessingProvider.provider(withID: PostProcessingProvider.customID))
		settings.setBaseURL("http://evil.example/v1", for: "openai")
		settings.setBaseURL("http://127.0.0.1:1234/v1", for: custom.id)
		#expect(settings.baseURL(for: openAI) == "https://api.openai.com/v1")
		#expect(settings.baseURL(for: custom) == "http://127.0.0.1:1234/v1")
	}

	@Test(arguments: [
		// enabled, everyDictation, byShortcut, live, expected
		(false, true, true, false, false),
		(true, false, true, false, true),
		(true, false, false, false, false),
		(true, true, false, false, true),
		(true, true, false, true, false),
		(true, true, true, false, true),
	])
	func shouldPostProcessMatrix(args: (Bool, Bool, Bool, Bool, Bool)) {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.isEnabled = args.0
		settings.appliesToEveryDictation = args.1
		#expect(settings.shouldPostProcess(requestedByShortcut: args.2, isLiveMode: args.3) == args.4)
	}

	@Test func providerCatalogHasUniqueIDsAndValidURLs() {
		let ids = PostProcessingProvider.all.map(\.id)
		#expect(Set(ids).count == ids.count)
		for provider in PostProcessingProvider.all where provider.kind == .openAICompatible {
			#expect(OpenAICompatibleClient.endpoint(baseURL: provider.defaultBaseURL, path: "models") != nil)
		}
		#expect(ids.contains(PostProcessingProvider.appleIntelligenceID))
	}
}

// MARK: - Client

@Suite(.serialized)
struct OpenAICompatibleClientTests {
	@Test func endpointJoinsPaths() {
		#expect(
			OpenAICompatibleClient.endpoint(baseURL: "https://api.openai.com/v1/", path: "chat/completions")?
				.absoluteString == "https://api.openai.com/v1/chat/completions")
		#expect(OpenAICompatibleClient.endpoint(baseURL: "not a url", path: "models") == nil)
		#expect(OpenAICompatibleClient.endpoint(baseURL: "ftp://host/v1", path: "models") == nil)
		#expect(OpenAICompatibleClient.endpoint(baseURL: "", path: "models") == nil)
	}

	@Test func redactsKeyMaterial() {
		let message = "Incorrect API key provided: sk-proj-****abcd. Also secret-123456 leaked."
		let redacted = OpenAICompatibleClient.redacting("secret-123456", in: message)
		#expect(!redacted.contains("secret-123456"))
		#expect(!redacted.contains("sk-proj"))
	}

	@Test func sendsChatCompletionAndCleansResponse() async throws {
		let server = try MockHTTPServer { _ in
			chatCompletion("<think>reasoning</think>\nMeet at 3:30 tomorrow.")
		}
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(
			baseURL: server.baseURL, apiKey: "test-key-abc", model: "gpt-test", timeout: 5)
		let output = try await client.process(PostProcessingMessages(system: "Be tidy.", user: "um meet at three thirty"))
		#expect(output == "Meet at 3:30 tomorrow.")

		let request = try #require(server.requests.first)
		#expect(request.method == "POST")
		#expect(request.path == "/v1/chat/completions")
		#expect(request.header("Authorization") == "Bearer test-key-abc")
		#expect(request.header("Content-Type") == "application/json")
		let body = try #require(request.jsonBody)
		#expect(body["model"] as? String == "gpt-test")
		#expect(body["stream"] as? Bool == false)
		let messages = try #require(body["messages"] as? [[String: String]])
		#expect(messages == [["role": "system", "content": "Be tidy."], ["role": "user", "content": "um meet at three thirty"]])
	}

	@Test func omitsAuthorizationWithoutKeyAndSystemMessageWhenNil() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("ok") }
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: nil, model: "llama3", timeout: 5)
		_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))

		let request = try #require(server.requests.first)
		#expect(request.header("Authorization") == nil)
		let messages = try #require(request.jsonBody?["messages"] as? [[String: String]])
		#expect(messages == [["role": "user", "content": "hi"]])
	}

	@Test func listsModelsSorted() async throws {
		let server = try MockHTTPServer { request in
			#expect(request.path == "/v1/models")
			return .json(["object": "list", "data": [["id": "zeta"], ["id": "alpha"], ["id": "mid"]]])
		}
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: "k", model: "", timeout: 5)
		#expect(try await client.listModels() == ["alpha", "mid", "zeta"])
		#expect(server.requests.first?.method == "GET")
	}

	@Test func httpErrorSurfacesMessageWithoutKey() async throws {
		let key = "sk-live-supersecretvalue"
		let server = try MockHTTPServer { _ in
			.json(["error": ["message": "Incorrect API key provided: \(key)", "type": "invalid_request_error"]], status: 401)
		}
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: key, model: "m", timeout: 5)
		do {
			_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))
			Issue.record("Expected an HTTP error")
		} catch let error as PostProcessingError {
			guard case .httpStatus(let code, let message) = error else {
				Issue.record("Unexpected error \(error)")
				return
			}
			#expect(code == 401)
			#expect(message.contains("Incorrect API key provided"))
			#expect(!message.contains(key))
			#expect(!(error.errorDescription ?? "").contains(key))
		}
	}

	@Test func malformedJSONThrows() async throws {
		let server = try MockHTTPServer { _ in
			MockHTTPServer.Response(status: 200, body: Data("<html>gateway</html>".utf8), contentType: "text/html")
		}
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: nil, model: "m", timeout: 5)
		await #expect(throws: PostProcessingError.malformedResponse) {
			_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))
		}
	}

	@Test func emptyContentThrows() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("<think>only thinking</think>   ") }
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: nil, model: "m", timeout: 5)
		await #expect(throws: PostProcessingError.emptyResponse) {
			_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))
		}
	}
}

// MARK: - Service

@Suite(.serialized)
struct PostProcessingServiceTests {
	private func customSettings(baseURL: String, model: String = "local-model") -> PostProcessingSettings {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.isEnabled = true
		settings.providerID = PostProcessingProvider.customID
		settings.setBaseURL(baseURL, for: PostProcessingProvider.customID)
		settings.setModel(model, for: PostProcessingProvider.customID)
		settings.timeoutSeconds = 5
		return settings
	}

	@Test func processesThroughConfiguredProviderWithSelectedPrompt() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("Cleaned text.") }
		try await server.start()
		defer { server.stop() }

		let settings = customSettings(baseURL: server.baseURL)
		settings.prompts = [PostProcessingPrompt(id: "shout", name: "Shout", template: "SHOUT: ${output}")]
		settings.selectedPromptID = "shout"
		let service = PostProcessingService(
			settings: settings, secrets: InMemorySecretStore([PostProcessingProvider.customID: "local-key"]))

		#expect(await service.process("um cleaned text") == .processed("Cleaned text."))
		let request = try #require(server.requests.first)
		#expect(request.header("Authorization") == "Bearer local-key")
		let messages = try #require(request.jsonBody?["messages"] as? [[String: String]])
		#expect(messages == [["role": "user", "content": "SHOUT: um cleaned text"]])
	}

	@Test func serverFailureFallsBackToOriginal() async throws {
		let server = try MockHTTPServer { _ in .json(["error": ["message": "overloaded"]], status: 503) }
		try await server.start()
		defer { server.stop() }

		let service = PostProcessingService(
			settings: customSettings(baseURL: server.baseURL), secrets: InMemorySecretStore())
		let outcome = await service.process("raw words")
		#expect(outcome.text == "raw words")
		guard case .failed(_, let error) = outcome else {
			Issue.record("Expected failure, got \(outcome)")
			return
		}
		#expect(error.contains("503"))
	}

	@Test func blankTranscriptSkipsNetwork() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("should not be called") }
		try await server.start()
		defer { server.stop() }

		let service = PostProcessingService(
			settings: customSettings(baseURL: server.baseURL), secrets: InMemorySecretStore())
		#expect(await service.process("  \n") == .skipped(original: "  \n"))
		#expect(server.requests.isEmpty)
	}

	@Test func hostedProviderWithoutKeyFailsWithoutNetwork() async throws {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.providerID = "openai"
		settings.setModel("gpt-4o-mini", for: "openai")
		let service = PostProcessingService(settings: settings, secrets: InMemorySecretStore())
		#expect(await service.process("hello") == .failed(original: "hello", error: "No API key saved for OpenAI"))
	}

	@Test func missingModelFails() async {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		settings.providerID = "groq"
		let service = PostProcessingService(settings: settings, secrets: InMemorySecretStore(["groq": "k"]))
		#expect(await service.process("hello") == .failed(original: "hello", error: "No model selected for Groq"))
	}

	@Test func appleIntelligenceProviderUsesOnDeviceProcessor() throws {
		let settings = PostProcessingSettings(defaults: isolatedDefaults())
		let service = PostProcessingService(settings: settings, secrets: InMemorySecretStore())
		let provider = try #require(PostProcessingProvider.provider(withID: PostProcessingProvider.appleIntelligenceID))
		#expect(try service.makeProcessor(for: provider) is AppleIntelligenceProcessor)
		#expect(provider.requiresAPIKey == false)
	}
}

// MARK: - Apple Intelligence

struct AppleIntelligenceProcessorTests {
	@Test func availabilityIsReportedWithoutCrashing() {
		let availability = AppleIntelligenceProcessor.availability()
		#expect(!availability.summary.isEmpty)
	}

	@Test func unavailableModelThrowsTypedError() async throws {
		let availability = AppleIntelligenceProcessor.availability()
		guard !availability.isAvailable else { return }
		await #expect(throws: PostProcessingError.appleIntelligenceUnavailable(reason: availability.summary)) {
			_ = try await AppleIntelligenceProcessor().process(PostProcessingMessages(system: nil, user: "hi"))
		}
	}

	@Test(.enabled(if: AppleIntelligenceProcessor.availability().isAvailable, "Apple Intelligence not available here"))
	func cleansTextOnDevice() async throws {
		let output = try await AppleIntelligenceProcessor().process(
			PostProcessingPrompt.defaultCleanup.messages(for: "um so uh the meeting is at three pm period"))
		#expect(!output.isEmpty)
		#expect(!output.localizedCaseInsensitiveContains("<think>"))
		#expect(output.localizedCaseInsensitiveContains("meeting"), "Output: \(output)")
		let words = output.lowercased().split(whereSeparator: { !$0.isLetter })
		#expect(!words.contains("um") && !words.contains("uh"), "Output: \(output)")
	}

	/// Drives the provider the way a dictation does: settings pick Apple Intelligence and the
	/// service runs the selected prompt through the on-device model.
	@Test(
		.enabled(if: AppleIntelligenceProcessor.availability().isAvailable, "Apple Intelligence not available here"),
		.timeLimit(.minutes(2)))
	func serviceProcessesThroughAppleIntelligence() async throws {
		let suite = "AppleIntelligenceProcessorTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let settings = PostProcessingSettings(defaults: defaults)
		settings.providerID = PostProcessingProvider.appleIntelligenceID
		let service = PostProcessingService(settings: settings, secrets: InMemorySecretStore())

		let outcome = await service.process("uh so the budget review moved to friday")

		guard case .processed(let text) = outcome else {
			Issue.record("Expected an on-device result, got \(outcome)")
			return
		}
		#expect(text.localizedCaseInsensitiveContains("budget"), "Output: \(text)")
		#expect(text.localizedCaseInsensitiveContains("friday"), "Output: \(text)")
	}
}

// MARK: - Keychain

/// Over SSH the login keychain can accept an add yet refuse a later update or read, so the
/// probe exercises every call the keychain tests make.
private let keychainAvailable: Bool = {
	let store = KeychainSecretStore(service: "com.macwhisper.app.tests.probe.\(UUID().uuidString)")
	defer { try? store.setAPIKey(nil, for: "probe") }
	do {
		try store.setAPIKey("probe", for: "probe")
		try store.setAPIKey("probe-2", for: "probe")
		guard try store.apiKey(for: "probe") == "probe-2" else { return false }
		try store.setAPIKey(nil, for: "probe")
		return try store.apiKey(for: "probe") == nil
	} catch {
		return false
	}
}()

struct KeychainSecretStoreTests {
	@Test(.enabled(if: keychainAvailable, "Login keychain is locked in this session"))
	func roundTripUpdateAndDelete() throws {
		let store = KeychainSecretStore(service: "com.macwhisper.app.tests.\(UUID().uuidString)")
		defer { try? store.setAPIKey(nil, for: "openai") }

		#expect(try store.apiKey(for: "openai") == nil)
		try store.setAPIKey("  first-key \n", for: "openai")
		#expect(try store.apiKey(for: "openai") == "first-key")
		try store.setAPIKey("second-key", for: "openai")
		#expect(try store.apiKey(for: "openai") == "second-key")
		#expect(try store.apiKey(for: "groq") == nil)
		try store.setAPIKey("", for: "openai")
		#expect(try store.apiKey(for: "openai") == nil)
	}

	@Test func settingsNeverPersistKeys() {
		let defaults = isolatedDefaults()
		let settings = PostProcessingSettings(defaults: defaults)
		settings.setModel("m", for: "openai")
		let stored = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("postProcessing") }
		#expect(!stored.contains { $0.localizedCaseInsensitiveContains("key") })
	}
}

// MARK: - Shortcut

struct PostProcessShortcutTests {
	@Test func formatsModifiersInParserOrder() {
		#expect(PostProcessingShortcutFormatter.format(modifiers: [.option, .shift], key: "Space") == "⌥⇧Space")
		#expect(PostProcessingShortcutFormatter.format(modifiers: [.command, .control], key: "P") == "⌘⌃P")
	}

	@Test func rejectsModifierOnlyOrEmptyShortcut() {
		#expect(!PostProcessShortcutMonitor.isUsableShortcut(""))
		#expect(!PostProcessShortcutMonitor.isUsableShortcut("⌥⇧"))
		#expect(PostProcessShortcutMonitor.isUsableShortcut("⌥⇧Space"))
	}

	@Test func unknownKeysAreRejectedInsteadOfBecomingR() {
		#expect(ShortcutCombo("⌥⇧\u{F708}") == nil)
		#expect(ShortcutCombo("⌥⇧Å") == nil)
		#expect(!PostProcessShortcutMonitor.isUsableShortcut("⌥⇧\u{F708}"))
		#expect(ShortcutCombo("⌥⌘R") == ShortcutCombo(modifiers: [.option, .command], keyCode: 15))
	}

	@Test func recorderNamesThePhysicalKey() {
		// Option-Shift-1 used to be stored as "⌥⇧!" and F5 as a private-use character
		#expect(PostProcessingShortcutFormatter.format(keyCode: 18, modifiers: [.option, .shift]) == "⌥⇧1")
		#expect(PostProcessingShortcutFormatter.format(keyCode: 96, modifiers: [.control]) == "⌃F5")
		#expect(PostProcessingShortcutFormatter.format(keyCode: 49, modifiers: [.option, .shift]) == "⌥⇧Space")
		#expect(PostProcessingShortcutFormatter.format(keyCode: 15, modifiers: []) == nil)
		#expect(PostProcessingShortcutFormatter.format(keyCode: 255, modifiers: [.command]) == nil)
	}

	@Test func everyNamedKeyRoundTripsToItsKeyCode() {
		for keyCode in UInt16(0)...UInt16(200) {
			guard let formatted = PostProcessingShortcutFormatter.format(keyCode: keyCode, modifiers: [.command])
			else { continue }
			#expect(ShortcutCombo(formatted) == ShortcutCombo(modifiers: [.command], keyCode: keyCode), "\(formatted)")
		}
	}

	@Test func legacyShiftedSymbolsResolveToTheirKey() {
		#expect(ShortcutCombo("⌥⇧!") == ShortcutCombo(modifiers: [.option, .shift], keyCode: 18))
		#expect(ShortcutCombo("⌘?") == ShortcutCombo(modifiers: [.command], keyCode: 44))
	}

	@Test func conflictsWithTheOtherWhisperaShortcutsAreFound() {
		let defaults = isolatedDefaults()
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌘⌥R", defaults: defaults) == "⌥⌘R")
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌃F", defaults: defaults) == "⌃F")
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌥⇧Space", defaults: defaults) == nil)

		defaults.set("⌃⇧D", forKey: "globalShortcut")
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⇧⌃D", defaults: defaults) == "⌃⇧D")
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌥⌘R", defaults: defaults) == nil)

		RecordingControlSettings(defaults: defaults).cancelShortcut = CancelShortcutBinding(
			keyCode: 2, modifiers: [.command, .shift], display: "⌘⇧D")
		#expect(PostProcessShortcutMonitor.conflictingShortcut(for: "⌘⇧D", defaults: defaults) == "⌘⇧D")
	}
}

struct PostProcessingKeyTransportTests {
	@Test(arguments: [
		("https://api.example.com/v1", true),
		("http://127.0.0.1:11434/v1", true),
		("http://localhost:1234/v1", true),
		("http://[::1]:8080/v1", true),
		("http://127.1.2.3:8080/v1", true),
		("http://127.attacker.example/v1", false),
		("http://127.0.0.1.nip.io/v1", false),
		("http://evil.localhost/v1", false),
		("http://[::ffff:127.0.0.1]:8080/v1", true),
		("http://[::2]:8080/v1", false),
		("http://llm.lan:8080/v1", false),
		("http://192.168.1.20:11434/v1", false),
		("http://api.example.com/v1", false),
	])
	func keyIsSentOverHttpOnlyToLoopback(baseURL: String, allowed: Bool) throws {
		let url = try #require(OpenAICompatibleClient.endpoint(baseURL: baseURL, path: "models"))
		#expect(OpenAICompatibleClient.canSendKey(to: url) == allowed)
		#expect((OpenAICompatibleClient.insecureKeyWarning(baseURL: baseURL, hasKey: true) == nil) == allowed)
		#expect(OpenAICompatibleClient.insecureKeyWarning(baseURL: baseURL, hasKey: false) == nil)
	}

	@Test func refusesToSendAKeyOverPlainHttpToARemoteHost() async {
		let client = OpenAICompatibleClient(
			baseURL: "http://203.0.113.9:8080/v1", apiKey: "sk-secret", model: "m", timeout: 1)
		await #expect(throws: PostProcessingError.insecureKeyTransport(host: "203.0.113.9")) {
			_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))
		}
	}

	@Test func redirectToAnotherOriginDropsTheKey() async throws {
		let target = try MockHTTPServer { _ in chatCompletion("done") }
		try await target.start()
		defer { target.stop() }
		let origin = try MockHTTPServer { _ in
			MockHTTPServer.Response(
				status: 307, body: Data(),
				headers: ["Location": "http://127.0.0.1:\(target.port)/v1/chat/completions"])
		}
		try await origin.start()
		defer { origin.stop() }

		let client = OpenAICompatibleClient(baseURL: origin.baseURL, apiKey: "sk-secret-key", model: "m", timeout: 5)
		let output = try await client.process(PostProcessingMessages(system: nil, user: "hi"))

		#expect(output == "done")
		#expect(origin.requests.first?.header("Authorization") == "Bearer sk-secret-key")
		#expect(target.requests.count == 1)
		#expect(target.requests.first?.header("Authorization") == nil, "The key followed the redirect")
	}

	@Test func sameOriginRedirectKeepsTheKey() throws {
		var original = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
		original.setValue("Bearer k", forHTTPHeaderField: "Authorization")
		var proposed = URLRequest(url: URL(string: "https://api.example.com/v2/chat/completions")!)
		proposed.setValue("Bearer k", forHTTPHeaderField: "Authorization")
		#expect(
			OpenAICompatibleClient.redirectedRequest(proposed, from: original)
				.value(forHTTPHeaderField: "Authorization") == "Bearer k")

		for target in [
			"http://api.example.com/v1/chat/completions", "https://other.example.com/v1/chat/completions",
			"https://api.example.com:8443/v1/chat/completions",
		] {
			var redirect = URLRequest(url: URL(string: target)!)
			redirect.setValue("Bearer k", forHTTPHeaderField: "Authorization")
			#expect(
				OpenAICompatibleClient.redirectedRequest(redirect, from: original)
					.value(forHTTPHeaderField: "Authorization") == nil, "\(target)")
		}
	}

	@Test func keylessRequestsToLanServersStillWork() throws {
		let url = try #require(OpenAICompatibleClient.endpoint(baseURL: "http://192.168.1.20:11434/v1", path: "models"))
		#expect(!OpenAICompatibleClient.canSendKey(to: url))
		#expect(OpenAICompatibleClient.insecureKeyWarning(baseURL: "http://192.168.1.20:11434/v1", hasKey: false) == nil)
	}
}

struct KeychainPresenceTests {
	@Test(.enabled(if: keychainAvailable, "Login keychain is locked in this session"))
	func hasAPIKeyReflectsStoredItemsWithoutReadingThem() throws {
		let store = KeychainSecretStore(service: "com.macwhisper.app.tests.presence.\(UUID().uuidString)")
		defer { try? store.setAPIKey(nil, for: "openai") }

		#expect(try !store.hasAPIKey(for: "openai"))
		try store.setAPIKey("k", for: "openai")
		#expect(try store.hasAPIKey(for: "openai"))
		#expect(try !store.hasAPIKey(for: "groq"))
		try store.setAPIKey(nil, for: "openai")
		#expect(try !store.hasAPIKey(for: "openai"))
	}
}

// MARK: - Structured output

@Suite(.serialized)
struct StructuredOutputTests {
	@Test func providerFlagsMatchHandy() {
		let flags = Dictionary(
			uniqueKeysWithValues: PostProcessingProvider.all.map { ($0.id, $0.supportsStructuredOutput) })
		#expect(flags["openai"] == true)
		#expect(flags["openrouter"] == true)
		#expect(flags["cerebras"] == true)
		#expect(flags["zai"] == true)
		#expect(flags["bedrock_mantle"] == true)
		#expect(flags["anthropic"] == false)
		#expect(flags["groq"] == false)
		#expect(flags[PostProcessingProvider.customID] == false)
	}

	@Test func extractsTheTranscriptionField() {
		#expect(StructuredTranscription.extract(from: #"{"transcription":"Hello, world."}"#) == "Hello, world.")
		#expect(
			StructuredTranscription.extract(from: "<think>hmm</think>\n{\"transcription\": \"Hi.\"}") == "Hi.")
		#expect(StructuredTranscription.extract(from: "Plain text reply") == "Plain text reply")
		#expect(StructuredTranscription.extract(from: #"{"text":"wrong key"}"#) == #"{"text":"wrong key"}"#)
	}

	@Test func sendsJSONSchemaAndUnwrapsTheReply() async throws {
		let server = try MockHTTPServer { _ in chatCompletion(#"{"transcription":"Meet at 3:30."}"#) }
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(
			baseURL: server.baseURL, apiKey: "k", model: "gpt-test", timeout: 5, structuredOutput: true)
		let output = try await client.process(PostProcessingMessages(system: "Tidy.", user: "meet at three thirty"))
		#expect(output == "Meet at 3:30.")

		let body = try #require(server.requests.first?.jsonBody)
		let format = try #require(body["response_format"] as? [String: Any])
		#expect(format["type"] as? String == "json_schema")
		let jsonSchema = try #require(format["json_schema"] as? [String: Any])
		#expect(jsonSchema["strict"] as? Bool == true)
		let schema = try #require(jsonSchema["schema"] as? [String: Any])
		#expect(schema["required"] as? [String] == ["transcription"])
		#expect(schema["additionalProperties"] as? Bool == false)
		let properties = try #require(schema["properties"] as? [String: [String: String]])
		#expect(properties["transcription"]?["type"] == "string")
	}

	@Test func plainClientSendsNoResponseFormat() async throws {
		let server = try MockHTTPServer { _ in chatCompletion("ok") }
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(baseURL: server.baseURL, apiKey: nil, model: "llama3", timeout: 5)
		_ = try await client.process(PostProcessingMessages(system: nil, user: "hi"))
		#expect(server.requests.first?.jsonBody?["response_format"] == nil)
	}

	@Test func retriesWithoutSchemaWhenRejected() async throws {
		let server = try MockHTTPServer { request in
			if request.jsonBody?["response_format"] != nil {
				return .json(["error": ["message": "response_format is not supported by this model"]], status: 400)
			}
			return chatCompletion("Plain reply.")
		}
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(
			baseURL: server.baseURL, apiKey: "k", model: "m", timeout: 5, structuredOutput: true)
		#expect(try await client.process(PostProcessingMessages(system: nil, user: "x")) == "Plain reply.")
		#expect(server.requests.count == 2)
	}

	@Test func otherErrorsAreNotRetried() async throws {
		let server = try MockHTTPServer { _ in .json(["error": ["message": "bad key"]], status: 401) }
		try await server.start()
		defer { server.stop() }

		let client = OpenAICompatibleClient(
			baseURL: server.baseURL, apiKey: "k", model: "m", timeout: 5, structuredOutput: true)
		await #expect(throws: PostProcessingError.self) {
			try await client.process(PostProcessingMessages(system: nil, user: "x"))
		}
		#expect(server.requests.count == 1)
	}
}

struct PostProcessingConsentTests {
	@Test func consentNamesTheProviderThatReceivesTheTranscript() throws {
		let openAI = try #require(PostProcessingProvider.provider(withID: "openai"))
		#expect(openAI.consentText(baseURL: openAI.defaultBaseURL).contains("OpenAI"))

		let openRouter = try #require(PostProcessingProvider.provider(withID: "openrouter"))
		#expect(openRouter.consentText(baseURL: openRouter.defaultBaseURL).contains("OpenRouter"))

		let custom = try #require(PostProcessingProvider.provider(withID: PostProcessingProvider.customID))
		#expect(custom.consentText(baseURL: "https://llm.example.org/v1").contains("llm.example.org"))

		let apple = try #require(PostProcessingProvider.provider(withID: PostProcessingProvider.appleIntelligenceID))
		#expect(apple.consentText(baseURL: "").contains("Apple Intelligence"))
	}
}
