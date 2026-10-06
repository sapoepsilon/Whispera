// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaOpenAI

/// What the last request to a configured server found out, as the one status
/// line under it shows it.
///
/// A server that answered is reachable, whatever it answered. The Local Network
/// advice is only for a request that got no response at all; an HTTP 401 or
/// 403 is a key problem and is shown next to the key field instead.
enum ServerCheck: Equatable {
	case idle
	case checking
	case listed(count: Int)
	case passed(String)
	case needsKey
	case keyRejected
	case unreachable(String)
	case failed(String)

	enum Tone: Equatable {
		case neutral, success, warning, failure
	}

	var isKeyProblem: Bool { self == .needsKey || self == .keyRejected }

	var message: String? {
		switch self {
		case .idle: return nil
		case .checking: return String(localized: "Checking…")
		case .listed(let count):
			return String(format: String(localized: "Connected · %lld models"), Int64(count))
		case .passed(let text), .unreachable(let text), .failed(let text): return text
		case .needsKey: return String(localized: "Server needs an API key")
		case .keyRejected: return String(localized: "The server rejected this API key")
		}
	}

	var tone: Tone {
		switch self {
		case .idle, .checking: return .neutral
		case .listed, .passed: return .success
		case .unreachable: return .warning
		case .needsKey, .keyRejected, .failed: return .failure
		}
	}

	static func classify(_ error: Error, hasKey: Bool, destination: URL) -> ServerCheck {
		if let error = error as? OpenAIError {
			switch error {
			case .http(let status, _) where status == 401 || status == 403:
				return hasKey ? .keyRejected : .needsKey
			case .unreachable(_, let reason, _):
				return .unreachable(unreachableMessage(reason: reason, destination: destination))
			default:
				return .failed(error.errorDescription ?? error.localizedDescription)
			}
		}
		if let error = error as? URLError {
			return .unreachable(
				unreachableMessage(
					reason: OpenAITransportRetryPolicy.shortReason(for: error), destination: destination))
		}
		return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
	}

	static func unreachableMessage(reason: String, destination: URL) -> String {
		let host = destination.host ?? destination.absoluteString
		if LocalNetworkAccess.readsAsDenial(reason) {
			return String(
				localized:
					"macOS blocked Whispera from reaching \(host). Allow it under System Settings > Privacy & Security > Local Network."
			)
		}
		if LocalNetworkAccess.needsLocalNetworkGrant(url: destination) {
			return String(
				localized:
					"Couldn't reach \(host): \(reason). If the server is running, allow Whispera under System Settings > Privacy & Security > Local Network."
			)
		}
		return String(localized: "Couldn't reach \(host): \(reason).")
	}

	/// The Test button: the smallest request that proves the URL, the key and
	/// the model together. A chat completion for the LLM server, a half-second
	/// silent clip for the speech server.
	static func test(entry: ServerEntry, client: OpenAICompatibleClient) async -> ServerCheck {
		guard let url = entry.url else {
			return .failed(String(localized: "Enter the server's base URL first."))
		}
		let model = entry.model.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !model.isEmpty else { return .failed(String(localized: "Choose a model first.")) }
		do {
			switch entry.capability {
			case .llm:
				_ = try await client.complete(system: nil, prompt: "Reply with the single word: OK", model: model)
				return .passed(String(localized: "Test passed: \(model) answered."))
			case .speech:
				let silence = [Float](repeating: 0, count: 8000)
				_ = try await client.transcribe(
					TranscriptionRequest(model: model, audio: .wav(samples: silence, filename: "test.wav")))
				return .passed(String(localized: "Test passed: \(model) transcribed a test clip."))
			}
		} catch {
			return classify(error, hasKey: entry.hasKey, destination: url)
		}
	}
}
