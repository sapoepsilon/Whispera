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
