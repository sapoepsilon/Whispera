// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

extension WhisperaSettings {
	private static let localURLKey = "whisperaLocalServerURL"
	private static let localModelKey = "whisperaLocalModel"

	/// Default points at a local OpenAI-compatible server (ollama). Works with
	/// any OpenAI-compatible runtime — llama-server, vLLM, LM Studio.
	static let defaultLocalServerURL = "http://localhost:11434/v1"

	static var localServerURLString: String {
		get { UserDefaults.standard.string(forKey: localURLKey) ?? defaultLocalServerURL }
		set { UserDefaults.standard.set(newValue, forKey: localURLKey) }
	}

	static var localServerURL: URL? {
		URL(string: localServerURLString.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	static var localModel: String {
		get { UserDefaults.standard.string(forKey: localModelKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: localModelKey) }
	}
}

enum LocalLLMError: LocalizedError {
	case unavailable
	case unreachable(url: String, reason: String, retried: Bool)
	case noModel
	case http(status: Int, body: String)
	case empty

	var errorDescription: String? {
		switch self {
		case .unavailable:
			return "No model server URL configured — set one in Settings or switch to BYOK."
		case .unreachable(let url, let reason, let retried):
			return "Couldn't reach the model server at \(url) — \(reason)."
				+ (retried ? " Retried once." : "")
		case .noModel:
			return "No model set. Choose a model in Settings or set one on the recipe."
		case .http(let status, let body):
			return "Model server error (HTTP \(status))\(body.isEmpty ? "" : ": \(body)")"
		case .empty:
			return "The model returned an empty response."
		}
	}
}

/// Classifies transport failures on the recipe LLM hop: which ones earn the
/// single retry, and the short phrase the HUD shows for them. Pure — no
/// network, no state — so the decision is unit-testable on its own.
enum LLMTransportRetryPolicy {
	/// Transient conditions where the server may simply be waking up or the
	/// route flickered — the exact failure the user hit against a proxy on
	/// another machine. HTTP status codes never come through here (they are
	/// real answers from a reachable server), and cancellation, TLS refusals,
	/// bad URLs and the like are not transient, so none of them retry.
	static let retryableCodes: Set<URLError.Code> = [
		.timedOut,
		.cannotConnectToHost,
		.cannotFindHost,
		.dnsLookupFailed,
		.networkConnectionLost,
		.notConnectedToInternet,
	]

	static func shouldRetry(_ code: URLError.Code) -> Bool {
		retryableCodes.contains(code)
	}

	/// HUD-sized phrasing for the common transport failures; anything else
	/// falls back to the system's own description.
	static func shortReason(for error: URLError) -> String {
		switch error.code {
		case .timedOut: return "the request timed out"
		case .cannotConnectToHost: return "the connection was refused"
		case .cannotFindHost, .dnsLookupFailed: return "the host was not found"
		case .networkConnectionLost: return "the connection was lost"
		case .notConnectedToInternet: return "the network is offline"
		default: return error.localizedDescription
		}
	}
}

/// Runs a recipe's `llm` steps against any OpenAI-compatible chat endpoint —
/// the user's local server by default, or a hosted provider when an API key is
/// supplied (the BYOK path).
///
/// ponytail: this is the "local" path until on-device Apple Foundation Models
/// (`SystemLanguageModel` / `LanguageModelSession`) is wired in — deferred for
/// now (no model footprint on this machine). Any OpenAI-compatible local
/// runtime (ollama / llama-server / vLLM / LM Studio) works today. WHI-38.
struct LocalLLMExecutor {
	/// A recipe runs while the user watches the HUD. URLSession's default 60s
	/// would leave them staring at a spinner for a minute before the fallback
	/// paste; 20s is long enough for a server to return a full (non-streamed)
	/// completion for recipe-sized prompts, and short enough that a dead hop
	/// fails while the user is still looking. Worst case with the one retry:
	/// ~41s, still under a single default timeout.
	static let requestTimeout: TimeInterval = 20

	/// Backoff before the single retry — enough for a sleeping proxy or a
	/// dropped route to come back, short enough to not add a visible stall.
	static let defaultRetryDelayNanoseconds: UInt64 = 1_000_000_000

	private let session: URLSession
	private let serverURLProvider: @Sendable () -> URL?
	private let defaultModelProvider: @Sendable () -> String
	private let apiKeyProvider: @Sendable () -> String?
	private let retryDelayNanoseconds: UInt64

	init(
		session: URLSession = .shared,
		serverURLProvider: @escaping @Sendable () -> URL? = { WhisperaSettings.localServerURL },
		defaultModelProvider: @escaping @Sendable () -> String = { WhisperaSettings.localModel },
		// Local servers and the proxies in front of them often want a bearer token;
		// empty/absent means no Authorization header, exactly as before.
		apiKeyProvider: @escaping @Sendable () -> String? = {
			(try? ByokKeyStore.shared.loadLocalServerKey()) ?? nil
		},
		retryDelayNanoseconds: UInt64 = LocalLLMExecutor.defaultRetryDelayNanoseconds
	) {
		self.session = session
		self.serverURLProvider = serverURLProvider
		self.defaultModelProvider = defaultModelProvider
		self.apiKeyProvider = apiKeyProvider
		self.retryDelayNanoseconds = retryDelayNanoseconds
	}

	/// Runs each step in order, feeding each step's output into the next.
	func run(recipe: Recipe, input: String) async throws -> String {
		var current = input
		var outputs: [String] = []
		for step in recipe.steps {
			let config = step.config
			let prompt = Self.interpolate(config.prompt, input: current, stepOutputs: outputs)
			let system = config.systemPrompt.map { Self.interpolate($0, input: current, stepOutputs: outputs) }
			current = try await chat(
				system: system, prompt: prompt, model: config.model, maxTokens: config.maxTokens)
			outputs.append(current)
		}
		return current
	}

	func chat(system: String?, prompt: String, model: String?, maxTokens: Int?) async throws -> String {
		guard let base = serverURLProvider() else { throw LocalLLMError.unavailable }
		let resolvedModel = (model?.isEmpty == false ? model : nil) ?? nonEmpty(defaultModelProvider())
		guard let resolvedModel else { throw LocalLLMError.noModel }

		var messages: [[String: String]] = []
		if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
		messages.append(["role": "user", "content": prompt])

		var payload: [String: Any] = ["model": resolvedModel, "messages": messages]
		if let maxTokens { payload["max_tokens"] = maxTokens }

		var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
		request.httpMethod = "POST"
		request.timeoutInterval = Self.requestTimeout
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if let key = apiKeyProvider(), !key.isEmpty {
			request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: payload)

		let (data, response) = try await send(request, server: base.absoluteString)

		guard let http = response as? HTTPURLResponse else { throw LocalLLMError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw LocalLLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}

		guard let content = Self.parseContent(data), !content.isEmpty else { throw LocalLLMError.empty }
		return content
	}

	/// Sends the request with one bounded retry on transient transport failures
	/// (see `LLMTransportRetryPolicy`). HTTP error statuses never reach this
	/// path — the server answered, so the caller reports them as-is. The
	/// wording deliberately says "model server", not "local": the configured
	/// endpoint may be a proxy on another machine.
	private func send(_ request: URLRequest, server: String) async throws -> (Data, URLResponse) {
		do {
			return try await session.data(for: request)
		} catch {
			let urlError = error as? URLError
			if urlError?.code == .cancelled { throw CancellationError() }
			guard let urlError, LLMTransportRetryPolicy.shouldRetry(urlError.code) else {
				let reason = urlError.map { LLMTransportRetryPolicy.shortReason(for: $0) }
					?? error.localizedDescription
				AppLogger.shared.network.error(
					"Model server request to \(server) failed, not retryable: \(reason)")
				throw LocalLLMError.unreachable(url: server, reason: reason, retried: false)
			}
			AppLogger.shared.network.info(
				"Model server request to \(server) failed (\(LLMTransportRetryPolicy.shortReason(for: urlError))); retrying once")
			try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
			try Task.checkCancellation()
			do {
				return try await session.data(for: request)
			} catch {
				if (error as? URLError)?.code == .cancelled { throw CancellationError() }
				let reason = (error as? URLError).map { LLMTransportRetryPolicy.shortReason(for: $0) }
					?? error.localizedDescription
				AppLogger.shared.network.error(
					"Model server request to \(server) failed again after retry: \(reason)")
				throw LocalLLMError.unreachable(url: server, reason: reason, retried: true)
			}
		}
	}

	private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

	// MARK: - Helpers

	static func parseContent(_ data: Data) -> String? {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let choices = object["choices"] as? [[String: Any]],
			let message = choices.first?["message"] as? [String: Any],
			let content = message["content"] as? String
		else { return nil }
		return content.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Mirrors the backend `llm` handler's template syntax for the subset v1 uses.
	static func interpolate(_ template: String, input: String, stepOutputs: [String]) -> String {
		var result = template.replacingOccurrences(of: "{{input}}", with: input)
		for (index, output) in stepOutputs.enumerated() {
			result = result.replacingOccurrences(of: "{{steps[\(index)].output}}", with: output)
		}
		return result
	}
}
