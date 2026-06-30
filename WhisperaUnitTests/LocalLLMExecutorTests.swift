import Foundation
import Testing

@testable import Whispera

struct LocalLLMInterpolationTests {

	@Test func interpolatesInput() {
		let out = LocalLLMExecutor.interpolate("Fix: {{input}}", input: "hello", stepOutputs: [])
		#expect(out == "Fix: hello")
	}

	@Test func interpolatesPriorStepOutputs() {
		let out = LocalLLMExecutor.interpolate(
			"prev: {{steps[0].output}} and {{input}}", input: "now", stepOutputs: ["first"])
		#expect(out == "prev: first and now")
	}

	@Test func parsesOpenAIChatContent() {
		let json = #"{"choices":[{"message":{"role":"assistant","content":"  Hello there  "}}]}"#
		#expect(LocalLLMExecutor.parseContent(Data(json.utf8)) == "Hello there")
	}

	@Test func parseReturnsNilForGarbage() {
		#expect(LocalLLMExecutor.parseContent(Data("not json".utf8)) == nil)
	}
}

@Suite(.serialized)
struct LocalLLMExecutorChatTests {

	private func executor(model: String = "test-model") -> LocalLLMExecutor {
		let config = URLSessionConfiguration.ephemeral
		config.protocolClasses = [MockURLProtocol.self]
		let session = URLSession(configuration: config)
		return LocalLLMExecutor(
			session: session,
			serverURLProvider: { URL(string: "http://localhost:11434/v1") },
			defaultModelProvider: { model })
	}

	@Test func chatPostsOpenAIPayloadAndReturnsContent() async throws {
		MockURLProtocol.handler = { request in
			let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return (r, Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8))
		}
		let result = try await executor().chat(system: nil, prompt: "say hi", model: nil, maxTokens: 50)
		#expect(result == "hi")
		#expect(MockURLProtocol.lastRequest?.url?.path == "/v1/chat/completions")
		#expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
	}

	@Test func noModelThrows() async {
		let exec = executor(model: "")
		await #expect(throws: LocalLLMError.self) {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
		}
	}

	@Test func runChainsStepsFeedingOutputForward() async throws {
		// Each call echoes the user content so we can prove the chain wires step N → N+1.
		MockURLProtocol.handler = { request in
			let body = request.httpBodyStreamData() ?? request.httpBody ?? Data()
			let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
			let messages = object?["messages"] as? [[String: String]]
			let content = messages?.last?["content"] ?? ""
			let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			let json = try! JSONSerialization.data(withJSONObject: [
				"choices": [["message": ["content": "[\(content)]"]]]
			])
			return (r, json)
		}
		let recipe = Recipe(
			name: "chain",
			steps: [
				RecipeStep(config: LLMStepConfig(prompt: "a:{{input}}")),
				RecipeStep(config: LLMStepConfig(prompt: "b:{{input}}")),
			])
		let result = try await executor().run(recipe: recipe, input: "x")
		#expect(result == "[b:[a:x]]")
	}
}

extension URLRequest {
	/// URLProtocol delivers the body via a stream; read it back for assertions.
	fileprivate func httpBodyStreamData() -> Data? {
		guard let stream = httpBodyStream else { return nil }
		stream.open()
		defer { stream.close() }
		var data = Data()
		let size = 4096
		let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
		defer { buffer.deallocate() }
		while stream.hasBytesAvailable {
			let read = stream.read(buffer, maxLength: size)
			if read <= 0 { break }
			data.append(buffer, count: read)
		}
		return data
	}
}
