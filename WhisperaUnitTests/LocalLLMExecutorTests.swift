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

struct LLMTransportRetryPolicyTests {

	@Test func retriesTransientTransportFailures() {
		let transient: [URLError.Code] = [
			.timedOut, .cannotConnectToHost, .cannotFindHost,
			.dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
		]
		for code in transient {
			#expect(LLMTransportRetryPolicy.shouldRetry(code), "\(code) should be retryable")
		}
	}

	@Test func neverRetriesRealAnswersOrCancellation() {
		let notTransient: [URLError.Code] = [
			.cancelled, .badURL, .badServerResponse,
			.userAuthenticationRequired, .secureConnectionFailed,
			.appTransportSecurityRequiresSecureConnection,
		]
		for code in notTransient {
			#expect(!LLMTransportRetryPolicy.shouldRetry(code), "\(code) must not be retryable")
		}
	}

	@Test func shortReasonsStayHUDSized() {
		#expect(LLMTransportRetryPolicy.shortReason(for: URLError(.timedOut)) == "the request timed out")
		#expect(
			LLMTransportRetryPolicy.shortReason(for: URLError(.cannotConnectToHost))
				== "the connection was refused")
		#expect(
			LLMTransportRetryPolicy.shortReason(for: URLError(.cannotFindHost)) == "the host was not found")
		#expect(
			LLMTransportRetryPolicy.shortReason(for: URLError(.networkConnectionLost))
				== "the connection was lost")
		#expect(
			LLMTransportRetryPolicy.shortReason(for: URLError(.notConnectedToInternet))
				== "the network is offline")
	}

	@Test func unreachableMessageNamesServerReasonAndRetry() {
		let retried = LocalLLMError.unreachable(
			url: "http://192.168.50.190:8317/v1", reason: "the request timed out", retried: true)
		#expect(
			retried.errorDescription
				== "Couldn't reach the model server at http://192.168.50.190:8317/v1 — the request timed out. Retried once.")

		let single = LocalLLMError.unreachable(
			url: "http://192.168.50.190:8317/v1", reason: "the connection was lost", retried: false)
		#expect(
			single.errorDescription
				== "Couldn't reach the model server at http://192.168.50.190:8317/v1 — the connection was lost.")
	}

	@Test func unavailableMessageIsAboutConfigurationOnly() {
		#expect(
			LocalLLMError.unavailable.errorDescription
				== "No model server URL configured — set one in Settings or switch to BYOK.")
	}
}

/// Thread-safe attempt counter for handlers that must behave differently per call.
private final class AttemptCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0

	func next() -> Int {
		lock.lock()
		defer { lock.unlock() }
		count += 1
		return count
	}

	var value: Int {
		lock.lock()
		defer { lock.unlock() }
		return count
	}
}

struct LocalLLMExecutorRetryTests {

	private func executor(mock: MockURLProtocol.Mock) -> LocalLLMExecutor {
		LocalLLMExecutor(
			session: mock.session,
			serverURLProvider: { mock.baseURL.appendingPathComponent("v1") },
			defaultModelProvider: { "test-model" },
			apiKeyProvider: { nil },
			retryDelayNanoseconds: 1_000_000)
	}

	@Test func transientFailureIsRetriedOnceAndSucceeds() async throws {
		let attempts = AttemptCounter()
		let mock = MockURLProtocol.makeResult { request in
			guard attempts.next() > 1 else { return .failure(URLError(.cannotConnectToHost)) }
			let response = HTTPURLResponse(
				url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return .success((response, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)))
		}
		let result = try await executor(mock: mock).chat(
			system: nil, prompt: "x", model: nil, maxTokens: nil)
		#expect(result == "ok")
		#expect(attempts.value == 2)
	}

	@Test func persistentTransientFailureThrowsUnreachableAfterTwoAttempts() async {
		let attempts = AttemptCounter()
		let mock = MockURLProtocol.makeResult { _ in
			_ = attempts.next()
			return .failure(URLError(.timedOut))
		}
		let exec = executor(mock: mock)
		do {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
			Issue.record("expected LocalLLMError.unreachable")
		} catch let error as LocalLLMError {
			guard case .unreachable(_, let reason, let retried) = error else {
				Issue.record("expected .unreachable, got \(error)")
				return
			}
			#expect(reason == "the request timed out")
			#expect(retried)
			#expect(error.errorDescription?.hasSuffix("Retried once.") == true)
		} catch {
			Issue.record("unexpected error \(error)")
		}
		#expect(attempts.value == 2)
	}

	@Test func httpErrorIsNeverRetried() async {
		let attempts = AttemptCounter()
		let mock = MockURLProtocol.makeResult { request in
			_ = attempts.next()
			let response = HTTPURLResponse(
				url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
			return .success((response, Data("boom".utf8)))
		}
		let exec = executor(mock: mock)
		do {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
			Issue.record("expected LocalLLMError.http")
		} catch let error as LocalLLMError {
			guard case .http(let status, _) = error else {
				Issue.record("expected .http, got \(error)")
				return
			}
			#expect(status == 500)
		} catch {
			Issue.record("unexpected error \(error)")
		}
		#expect(attempts.value == 1)
	}

	@Test func nonTransientTransportFailureIsNotRetried() async {
		let attempts = AttemptCounter()
		let mock = MockURLProtocol.makeResult { _ in
			_ = attempts.next()
			return .failure(URLError(.badServerResponse))
		}
		let exec = executor(mock: mock)
		do {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
			Issue.record("expected LocalLLMError.unreachable")
		} catch let error as LocalLLMError {
			guard case .unreachable(_, _, let retried) = error else {
				Issue.record("expected .unreachable, got \(error)")
				return
			}
			#expect(!retried)
			#expect(error.errorDescription?.contains("Retried") == false)
		} catch {
			Issue.record("unexpected error \(error)")
		}
		#expect(attempts.value == 1)
	}

	@Test func unconfiguredServerThrowsUnavailableWithoutTouchingNetwork() async {
		let attempts = AttemptCounter()
		let mock = MockURLProtocol.makeResult { request in
			_ = attempts.next()
			let response = HTTPURLResponse(
				url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
			return .success((response, Data()))
		}
		let exec = LocalLLMExecutor(
			session: mock.session,
			serverURLProvider: { nil },
			defaultModelProvider: { "test-model" },
			apiKeyProvider: { nil },
			retryDelayNanoseconds: 1_000_000)
		do {
			_ = try await exec.chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
			Issue.record("expected LocalLLMError.unavailable")
		} catch let error as LocalLLMError {
			guard case .unavailable = error else {
				Issue.record("expected .unavailable, got \(error)")
				return
			}
		} catch {
			Issue.record("unexpected error \(error)")
		}
		#expect(attempts.value == 0)
	}

	@Test func requestCarriesDeliberateTimeout() async throws {
		let mock = MockURLProtocol.make(
			status: 200, json: #"{"choices":[{"message":{"content":"hi"}}]}"#)
		_ = try await executor(mock: mock).chat(system: nil, prompt: "x", model: nil, maxTokens: nil)
		#expect(
			MockURLProtocol.lastRequest(host: mock.host)?.timeoutInterval
				== LocalLLMExecutor.requestTimeout)
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
