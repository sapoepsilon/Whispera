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

	@Test func parsesModelIDsSortedAndDeduped() {
		let json = #"{"object":"list","data":[{"id":"gpt-5.5"},{"id":"claude-opus-5"},{"id":"gpt-5.5"}]}"#
		#expect(LocalLLMExecutor.parseModelIDs(Data(json.utf8)) == ["claude-opus-5", "gpt-5.5"])
	}

	@Test func parseModelIDsSkipsMalformedEntries() {
		let json = #"{"data":[{"id":"good"},{"name":"no-id"},{"id":""}]}"#
		#expect(LocalLLMExecutor.parseModelIDs(Data(json.utf8)) == ["good"])
	}

	@Test func parseModelIDsReturnsEmptyForGarbage() {
		#expect(LocalLLMExecutor.parseModelIDs(Data("not json".utf8)).isEmpty)
	}
}

struct LocalLLMExecutorChatTests {

	private func executor(mock: MockURLProtocol.Mock, model: String = "test-model") -> LocalLLMExecutor {
		LocalLLMExecutor(
			session: mock.session,
			serverURLProvider: { mock.baseURL.appendingPathComponent("v1") },
			defaultModelProvider: { model })
	}

	@Test func chatPostsOpenAIPayloadAndReturnsContent() async throws {
		let mock = MockURLProtocol.make(status: 200, json: #"{"choices":[{"message":{"content":"hi"}}]}"#)
		let result = try await executor(mock: mock).chat(
			system: nil, prompt: "say hi", model: nil, maxTokens: 50)
		#expect(result == "hi")
		#expect(MockURLProtocol.lastRequest(host: mock.host)?.url?.path == "/v1/chat/completions")
		#expect(MockURLProtocol.lastRequest(host: mock.host)?.httpMethod == "POST")
	}

	@Test func noModelThrows() async {
		let mock = MockURLProtocol.make(status: 200, json: #"{}"#)
		let exec = executor(mock: mock, model: "")
		await #expect(throws: LocalLLMError.self) {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
		}
	}

	@Test func runChainsStepsFeedingOutputForward() async throws {
		// Each call echoes the user content so we can prove the chain wires step N → N+1.
		let mock = MockURLProtocol.make { request in
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
		let result = try await executor(mock: mock).run(recipe: recipe, input: "x")
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
