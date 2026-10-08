import Foundation
import WhisperaRecipes
import WhisperaOpenAI

/// Paired clients use the owner's existing recipes and LLM server. Catalogs
/// expose labels only; credentials and prompt templates stay on this Mac.
public final class MacRecipeService: @unchecked Sendable {
    private let file: URL
    private let domain: String
    let keyStore: SpeechKeyStoring
    private let session: URLSession?
    public init(file: URL? = nil, domain: String = "com.macwhisper.app", keyStore: SpeechKeyStoring = KeychainSpeechKeyStore(service: "com.whispera.link.recipe-server"), session: URLSession? = nil) {
        self.session = session
        self.keyStore = keyStore
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whispera/recipes.json")
        self.domain = domain
    }
    private func recipes() throws -> [Recipe] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 2 * 1024 * 1024 else { throw APIError(503, "recipes_unavailable", "The Mac's recipe file is too large.") }
        do { return try JSONDecoder().decode([Recipe].self, from: data) }
        catch { throw APIError(503, "recipes_unavailable", "The Mac's saved recipes couldn't be read. Open Whispera Settings → Commands on the Mac.") }
    }
    private func setting(_ key: String) -> String {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String ?? ""
    }
    private func server() -> (URL, String)? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let base = AppSpeechSelection.normalize(setting("whisperaLocalServerURL")),
              let url = URL(string: base), ["http", "https"].contains(url.scheme ?? ""),
              !setting("whisperaLocalModel").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (url, setting("whisperaLocalModel"))
    }
    public func catalog() throws -> [String: Any] {
        let entries = try recipes()
        let issue = configurationIssue()
        return ["recipes": entries.map { ["id": $0.id, "name": $0.name, "description": $0.description ?? ""] },
                "ready": issue == nil, "message": issue ?? NSNull()]
    }
    private func configurationIssue() -> String? {
        guard let (url, _) = server() else { return "Add an LLM server and model in Whispera Settings → Servers on the Mac to run recipes." }
        if url.host?.lowercased() == "api.openai.com" {
            guard let credential = keyStore.credential(), credential.baseURL == url.absoluteString, !credential.key.isEmpty else {
                return "Add the LLM server API key in Whispera Settings → Servers on your Mac. Original dictation still works."
            }
        }
        return nil
    }
    public func run(_ id: String, text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 8000 else {
            throw APIError(400, "bad_request", "Recipe text must contain 1–8000 characters.")
        }
        guard let recipe = try recipes().first(where: { $0.id == id }) else { throw APIError(404, "not_found", "This recipe is no longer on your Mac. Refresh the recipes.") }
        guard !recipe.steps.isEmpty, recipe.steps.count <= 8, recipe.steps.allSatisfy({ $0.type == "llm" }) else {
            throw APIError(422, "recipe_unavailable", "This recipe isn't supported on the phone. Your original text is safe.")
        }
        if let issue = configurationIssue() { throw APIError(503, "recipe_unavailable", issue) }
        guard let (url, model) = server() else { throw APIError(503, "recipe_unavailable", "Set up the Mac's LLM server and model first. Your original text is safe.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let client = OpenAICompatibleClient(baseURL: url, apiKeyProvider: { [keyStore] in
                let credential = keyStore.credential()
                return credential?.baseURL == url.absoluteString ? credential?.key : nil
            },
            session: session ?? URLSession(configuration: configuration), configuration: .init(timeout: 10, retriesOnce: false))
        let pipeline = RecipePipeline.openAI(client: client, defaultModel: { model })
        do { return try SpeechService.runBlocking(timeout: 85) {
            do { return try await pipeline.run(recipe: recipe, input: text) }
            catch let error as OpenAIError {
                if case .http(let status, _) = error {
                    let message = [401, 403].contains(status) ? "The Mac's LLM server rejected its API key. Update the key in Whispera Settings → Servers. Your original text is safe." : "The Mac's LLM server returned HTTP \(status). Check its model and address in Whispera Settings → Servers. Your original text is safe."
                    throw APIError(502, "recipe_failed", message)
                }
                throw APIError(502, "recipe_failed", "The Mac couldn't process this recipe. Your original text is safe; check the LLM server on the Mac or try again.")
            } catch {
                throw APIError(502, "recipe_failed", "The Mac couldn't complete this recipe. Your original text is safe; check the LLM server on the Mac or try again.")
            }
        } } catch let error as APIError where error.status == 504 {
            throw APIError(504, "recipe_timeout", "The Mac's LLM server took too long. Your original text is safe; try again.")
        }
    }
}
