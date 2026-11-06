import Foundation
import XCTest
import WhisperaRecipes
@testable import LinkHelperCore

final class MacRecipeTests: XCTestCase {
    func testCatalogDoesNotExposePromptsAndNeverChangesRecipes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recipes.json")
        let data = try JSONEncoder().encode([Recipe(id: "fix", name: "Fix grammar", steps: [RecipeStep(config: LLMStepConfig(prompt: "private template {{input}}"))])])
        try data.write(to: file)
        let service = MacRecipeService(file: file, domain: "RecipeTests.\(UUID().uuidString)")
        let catalog = try service.catalog()
        let entries = try XCTUnwrap(catalog["recipes"] as? [[String: String]])
        XCTAssertEqual(entries.first?["name"], "Fix grammar")
        XCTAssertNil(entries.first?["steps"])
        XCTAssertFalse(catalog["ready"] as? Bool ?? true)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertThrowsError(try service.run("missing", text: "keep me")) { XCTAssertEqual(($0 as? APIError)?.status, 404) }
        XCTAssertThrowsError(try service.run("fix", text: "keep me")) { XCTAssertEqual(($0 as? APIError)?.status, 503) }
    }

    func testProcessingUsesBoundMacCredentialAndPreservesStoredRecipe() throws {
        let domain = "MacRecipeNetwork.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("https://recipes.qa/v1", forKey: "whisperaLocalServerURL")
        defaults.set("qa-model", forKey: "whisperaLocalModel")
        defaults.synchronize()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = try JSONEncoder().encode([Recipe(id: "fix", name: "Fix", steps: [RecipeStep(config: LLMStepConfig(prompt: "Correct: {{input}}"))])])
        try saved.write(to: file)
        let keys = MemorySpeechKeyStore(SpeechServerCredential(baseURL: "https://recipes.qa/v1", key: "generated-test-key"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecipeHTTPFixture.self]
        let service = MacRecipeService(file: file, domain: domain, keyStore: keys, session: URLSession(configuration: config))
        RecipeHTTPFixture.request = nil
        XCTAssertEqual(try service.run("fix", text: "hello world"), "Hello, world.")
        XCTAssertEqual(RecipeHTTPFixture.request?.url?.path, "/v1/chat/completions")
        XCTAssertEqual(RecipeHTTPFixture.request?.value(forHTTPHeaderField: "Authorization"), "Bearer generated-test-key")
        XCTAssertEqual(try Data(contentsOf: file), saved)
        defaults.set("https://api.openai.com/v1", forKey: "whisperaLocalServerURL"); defaults.synchronize()
        XCTAssertFalse(try service.catalog()["ready"] as? Bool ?? true, "A credential for a different server cannot enable the OpenAI server")
    }
    private func styledService(_ styles: AppStyleSettings?) throws -> (MacRecipeService, () -> [String: Any]?, () -> Void) {
        let domain = "MacRecipeStyle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set("https://recipes.qa/v1", forKey: "whisperaLocalServerURL")
        defaults.set("qa-model", forKey: "whisperaLocalModel")
        defaults.synchronize()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recipesFile = dir.appendingPathComponent("recipes.json")
        try JSONEncoder().encode([Recipe(id: AppStyleComposer.cleanUpRecipeID, name: "Clean up", steps: [RecipeStep(config: LLMStepConfig(prompt: "Clean: {{input}}"))])]).write(to: recipesFile)
        if let styles { try AppStyleSettingsStore(fileURL: dir.appendingPathComponent("app-styles.json")).save(styles) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecipeHTTPFixture.self]
        let service = MacRecipeService(file: recipesFile, domain: domain, keyStore: MemorySpeechKeyStore(), session: URLSession(configuration: config))
        RecipeHTTPFixture.request = nil
        let body: () -> [String: Any]? = {
            guard let stream = RecipeHTTPFixture.request?.httpBodyStream else { return RecipeHTTPFixture.request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return (service, body, { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: dir) })
    }

    private func systemPrompt(_ body: [String: Any]?) -> String? {
        (body?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "system" }?["content"] as? String
    }

    func testHostBundleIDOfIOSSlackGetsTheWorkStyle() throws {
        var styles = AppStyleSettings.defaults; styles.enabled = true; styles.styles[.work] = .excited
        let (service, body, cleanup) = try styledService(styles); defer { cleanup() }
        let result = try service.runStyled(AppStyleComposer.cleanUpRecipeID, text: "thanks so much", hostBundleID: "com.tinyspeck.chatlyio", styleOverride: nil)
        XCTAssertEqual(result.text, "Hello, world.")
        XCTAssertEqual(result.style?.category, .work)
        XCTAssertEqual(result.style?.style, .excited)
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.excited, category: .work))
    }

    func testUnknownHostFormatsAsOther() throws {
        var styles = AppStyleSettings.defaults; styles.enabled = true
        let (service, body, cleanup) = try styledService(styles); defer { cleanup() }
        let result = try service.runStyled(AppStyleComposer.cleanUpRecipeID, text: "hi", hostBundleID: "com.example.unknown", styleOverride: nil)
        XCTAssertEqual(result.style?.category, .other)
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.formal, category: .other))
    }

    func testRunWithoutTheFieldBehavesAsBefore() throws {
        let (service, body, cleanup) = try styledService(nil); defer { cleanup() }
        XCTAssertEqual(try service.run(AppStyleComposer.cleanUpRecipeID, text: "hi"), "Hello, world.")
        XCTAssertNil(systemPrompt(body()))
        var styles = AppStyleSettings.defaults; styles.enabled = false
        let (off, offBody, offCleanup) = try styledService(styles); defer { offCleanup() }
        let result = try off.runStyled(AppStyleComposer.cleanUpRecipeID, text: "hi", hostBundleID: "com.apple.MobileSMS", styleOverride: nil)
        XCTAssertNil(result.style)
        XCTAssertNil(systemPrompt(offBody()))
    }

    func testStyleOverrideWinsEvenWhenStylesAreOff() throws {
        let (service, body, cleanup) = try styledService(nil); defer { cleanup() }
        let result = try service.runStyled(AppStyleComposer.cleanUpRecipeID, text: "hi", hostBundleID: "com.apple.MobileSMS", styleOverride: .veryCasual)
        XCTAssertEqual(result.style?.style, .veryCasual)
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.veryCasual, category: .personal))
    }

    func testCatalogCarriesAppStyles() throws {
        var styles = AppStyleSettings.defaults; styles.enabled = true
        let (service, _, cleanup) = try styledService(styles); defer { cleanup() }
        let appStyles = try XCTUnwrap(try service.catalog()["app_styles"] as? [String: Any])
        XCTAssertEqual(appStyles["enabled"] as? Bool, true)
        XCTAssertEqual((appStyles["styles"] as? [String: String])?["email"], "formal")
    }

    func testSignedRunTakesHostBundleIDAndHealthListsTheCapability() async throws {
        var styles = AppStyleSettings.defaults; styles.enabled = true
        let (service, body, cleanup) = try styledService(styles); defer { cleanup() }
        let helper = try TestDaemon(engine: FakeEngine(), recipes: service)
        defer { helper.stop() }
        let phone = try await helper.pairedPhone()
        let health = try await phone.call("GET", "/v1/health")
        XCTAssertTrue((health.json["capabilities"] as? [String] ?? []).contains("recipes.app_style.v1"))
        XCTAssertEqual(MacRecipeService.appStyleCapability, "recipes.app_style.v1")

        let mail = try await phone.call("POST", "/v1/recipes/\(AppStyleComposer.cleanUpRecipeID)/run", json: ["text": "hi bob", "host_bundle_id": "com.apple.mobilemail"])
        XCTAssertEqual(mail.status, 200)
        XCTAssertEqual(mail.json["text"] as? String, "Hello, world.")
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.formal, category: .email))

        let overridden = try await phone.call("POST", "/v1/recipes/\(AppStyleComposer.cleanUpRecipeID)/run", json: ["text": "hi bob", "host_bundle_id": "com.apple.mobilemail", "style_override": "excited"])
        XCTAssertEqual(overridden.status, 200)
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.excited, category: .email))

        let plain = try await phone.call("POST", "/v1/recipes/\(AppStyleComposer.cleanUpRecipeID)/run", json: ["text": "hi bob", "style_override": "nonsense"])
        XCTAssertEqual(plain.status, 200)
        XCTAssertEqual(systemPrompt(body()), StyleFragment.text(.formal, category: .other))
    }

    func testRecipesUseSignedRoutes() throws {
        XCTAssertNotNil(LinkAPI.match("GET", "/v1/recipes"))
        XCTAssertNotNil(LinkAPI.match("POST", "/v1/recipes/fix/run"))
        XCTAssertNil(LinkAPI.match("GET", "/v1/recipes/fix/run"))
    }
}

private final class RecipeHTTPFixture: URLProtocol {
    static var request: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recipes.qa" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"Hello, world."}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
