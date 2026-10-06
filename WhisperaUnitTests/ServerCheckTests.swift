// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing
import WhisperaOpenAI

@testable import Whispera

/// The Servers pane's status line: a server that answered was reached, so only
/// a request with no response gets the Local Network advice, and a 401/403 is a
/// key problem.
struct ServerCheckTests {
	let lan = URL(string: "http://192.168.50.31:8317/v1")!
	let cloud = URL(string: "https://api.openai.com/v1")!

	@Test func a401FromALANServerIsAKeyProblemNotAReachabilityOne() {
		let error = OpenAIError.http(status: 401, body: "Missing API key")
		let check = ServerCheck.classify(error, hasKey: false, destination: lan)
		#expect(check == .needsKey)
		#expect(check.message == "Server needs an API key")
		#expect(check.isKeyProblem)
		#expect(!(check.message ?? "").contains("Local Network"))
	}

	@Test func aRejectedSavedKeyIsSaidAsSuch() {
		#expect(ServerCheck.classify(OpenAIError.http(status: 403, body: ""), hasKey: true, destination: cloud) == .keyRejected)
	}

	@Test func otherHTTPErrorsAreFailuresWithoutNetworkAdvice() {
		let check = ServerCheck.classify(OpenAIError.http(status: 404, body: "no such model"), hasKey: false, destination: lan)
		guard case .failed(let message) = check else {
			Issue.record("Expected a failure, got \(check)")
			return
		}
		#expect(message.contains("404"))
		#expect(!message.contains("Local Network"))
		#expect(check.tone == .failure)
	}

	@Test func noResponseFromALANServerMentionsTheLocalNetworkGrant() {
		let error = OpenAIError.unreachable(url: lan.absoluteString, reason: "the connection was refused", retried: true)
		let check = ServerCheck.classify(error, hasKey: false, destination: lan)
		guard case .unreachable(let message) = check else {
			Issue.record("Expected unreachable, got \(check)")
			return
		}
		#expect(message.contains("192.168.50.31"))
		#expect(message.contains("the connection was refused"))
		#expect(message.contains("Local Network"))
		#expect(check.tone == .warning)
	}

	@Test func noResponseFromACloudServerDoesNotMentionTheLocalNetwork() {
		let check = ServerCheck.classify(URLError(.timedOut), hasKey: true, destination: cloud)
		#expect(check == .unreachable("Couldn't reach api.openai.com: the request timed out."))
	}

	@Test func aLocalNetworkDenialSaysWhereToAllowIt() {
		let error = OpenAIError.unreachable(url: lan.absoluteString, reason: "Local network prohibited", retried: false)
		guard case .unreachable(let message) = ServerCheck.classify(error, hasKey: false, destination: lan) else {
			Issue.record("Expected unreachable")
			return
		}
		#expect(message.hasPrefix("macOS blocked Whispera"))
	}

	@Test func aListingReportsTheModelCount() {
		#expect(ServerCheck.listed(count: 3).message == "Connected · 3 models")
		#expect(ServerCheck.listed(count: 3).tone == .success)
	}
}

@Suite(.serialized)
struct ServerTestButtonTests {
	private func chatCompletion(_ content: String) -> MockHTTPServer.Response {
		.json(["choices": [["index": 0, "message": ["role": "assistant", "content": content]]]])
	}

	@Test func theLLMTestSendsATinyCompletionWithTheChosenModel() async throws {
		let server = try MockHTTPServer { _ in self.chatCompletion("OK") }
		try await server.start()
		defer { server.stop() }
		let entry = ServerEntry(capability: .llm, urlString: server.baseURL, model: "small-model")
		let client = OpenAICompatibleClient(baseURL: try #require(entry.url))

		let check = await ServerCheck.test(entry: entry, client: client)

		#expect(check == .passed("Test passed: small-model answered."))
		let request = try #require(server.requests.first)
		#expect(request.path == "/v1/chat/completions")
		#expect(request.jsonBody?["model"] as? String == "small-model")
	}

	@Test func theLLMTestReportsAMissingKey() async throws {
		let server = try MockHTTPServer { _ in .json(["error": ["message": "Missing API key"]], status: 401) }
		try await server.start()
		defer { server.stop() }
		let entry = ServerEntry(capability: .llm, urlString: server.baseURL, model: "m")
		let client = OpenAICompatibleClient(baseURL: try #require(entry.url))

		let check = await ServerCheck.test(entry: entry, client: client)

		#expect(check.isKeyProblem)
	}

	@Test func theSpeechTestTranscribesASilentClip() async throws {
		let server = try MockHTTPServer { _ in .json(["text": ""]) }
		try await server.start()
		defer { server.stop() }
		let entry = ServerEntry(capability: .speech, urlString: server.baseURL, model: "whisper-small")
		let client = OpenAICompatibleClient(baseURL: try #require(entry.url))

		let check = await ServerCheck.test(entry: entry, client: client)

		#expect(check == .passed("Test passed: whisper-small transcribed a test clip."))
		#expect(server.requests.first?.path == "/v1/audio/transcriptions")
	}

	@Test func aTestWithoutAModelAsksForOne() async throws {
		let entry = ServerEntry(capability: .llm, urlString: "http://127.0.0.1:9/v1", model: " ")
		let client = OpenAICompatibleClient(baseURL: try #require(entry.url))
		#expect(await ServerCheck.test(entry: entry, client: client) == .failed("Choose a model first."))
	}
}
