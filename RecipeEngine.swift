// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

// MARK: - Recipe Model

struct Recipe: Codable, Identifiable, Hashable, Sendable {
	let id: String
	let name: String
	let description: String?
	let triggerPhrase: String?
	let outputFormat: String
}

private struct RecipeListResponse: Decodable {
	let data: [Recipe]
}

private struct ExecuteRequest: Encodable {
	let input: String
	let stream: Bool
}

private struct ExecuteResponse: Decodable {
	let status: String
	let output: AnyOutput?
	let error: String?
}

private struct AnyOutput: Decodable {
	let stringValue: String?
	let rawDescription: String?

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let s = try? container.decode(String.self) {
			stringValue = s
			rawDescription = nil
		} else if container.decodeNil() {
			stringValue = nil
			rawDescription = nil
		} else if let n = try? container.decode(Double.self) {
			stringValue = nil
			rawDescription = "number(\(n))"
		} else if let b = try? container.decode(Bool.self) {
			stringValue = nil
			rawDescription = "bool(\(b))"
		} else {
			stringValue = nil
			rawDescription = "non-string-output"
		}
	}
}

// MARK: - Settings

enum RecipeSettings {
	private static let serverURLKey = "whisperaServerURL"
	private static let devTokenKey = "whisperaDevToken"

	static var serverURL: String {
		get { UserDefaults.standard.string(forKey: serverURLKey) ?? "http://localhost:3000" }
		set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
	}

	static var devToken: String {
		get { UserDefaults.standard.string(forKey: devTokenKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: devTokenKey) }
	}
}

// MARK: - API Client

enum WhisperaAPIError: LocalizedError {
	case invalidURL
	case missingToken
	case http(status: Int, body: String)
	case decoding(Error)
	case transport(Error)
	case unsupportedOutput(String)
	case empty

	var errorDescription: String? {
		switch self {
		case .invalidURL: return "Invalid Whispera server URL"
		case .missingToken: return "No auth token configured"
		case .http(let status, let body): return "HTTP \(status): \(body)"
		case .decoding(let err): return "Decoding failed: \(err.localizedDescription)"
		case .transport(let err): return "Network error: \(err.localizedDescription)"
		case .unsupportedOutput(let kind): return "Unsupported recipe output type: \(kind)"
		case .empty: return "Server returned no output"
		}
	}
}

final class WhisperaAPI: Sendable {
	private let session: URLSession
	private let decoder: JSONDecoder
	private let encoder: JSONEncoder

	init(session: URLSession = .shared) {
		self.session = session
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		self.decoder = d
		self.encoder = JSONEncoder()
	}

	private func baseURL() throws -> URL {
		guard let url = URL(string: RecipeSettings.serverURL) else {
			throw WhisperaAPIError.invalidURL
		}
		return url
	}

	private func token() throws -> String {
		let t = RecipeSettings.devToken
		guard !t.isEmpty else { throw WhisperaAPIError.missingToken }
		return t
	}

	private func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
		let url = try baseURL().appendingPathComponent(path)
		var req = URLRequest(url: url)
		req.httpMethod = method
		req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
		req.setValue("application/json", forHTTPHeaderField: "Accept")
		if let body {
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
			req.httpBody = body
		}
		return req
	}

	private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
		let (data, response): (Data, URLResponse)
		do {
			(data, response) = try await session.data(for: req)
		} catch {
			throw WhisperaAPIError.transport(error)
		}
		guard let http = response as? HTTPURLResponse else {
			throw WhisperaAPIError.http(status: -1, body: "no http response")
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? ""
			throw WhisperaAPIError.http(status: http.statusCode, body: body)
		}
		do {
			return try decoder.decode(T.self, from: data)
		} catch {
			throw WhisperaAPIError.decoding(error)
		}
	}

	func listRecipes() async throws -> [Recipe] {
		let req = try request(path: "/recipes")
		let resp = try await send(req, as: RecipeListResponse.self)
		return resp.data
	}

	func executeRecipe(id: String, input: String) async throws -> String {
		let body = try encoder.encode(ExecuteRequest(input: input, stream: false))
		let req = try request(path: "/recipes/\(id)/execute", method: "POST", body: body)
		let resp = try await send(req, as: ExecuteResponse.self)

		if resp.status != "completed" {
			throw WhisperaAPIError.http(status: 500, body: resp.error ?? "execution \(resp.status)")
		}
		if let s = resp.output?.stringValue, !s.isEmpty {
			return s
		}
		if let kind = resp.output?.rawDescription {
			throw WhisperaAPIError.unsupportedOutput(kind)
		}
		throw WhisperaAPIError.empty
	}
}

// MARK: - Cache

@MainActor
@Observable
final class RecipeCache {
	private(set) var recipes: [Recipe] = []
	private(set) var lastError: String?
	private(set) var isLoading = false

	private let api: WhisperaAPI

	init(api: WhisperaAPI) {
		self.api = api
	}

	func refresh() async {
		isLoading = true
		defer { isLoading = false }
		do {
			recipes = try await api.listRecipes()
			lastError = nil
			AppLogger.shared.network.info("RecipeCache: loaded \(recipes.count) recipes")
		} catch {
			lastError = error.localizedDescription
			AppLogger.shared.network.error("RecipeCache: refresh failed — \(error.localizedDescription)")
		}
	}
}

// MARK: - Matcher

struct RecipeMatch {
	let recipe: Recipe
	let remainingInput: String
}

enum RecipeMatcher {
	static func match(_ transcription: String, against recipes: [Recipe]) -> RecipeMatch? {
		let normalized = normalize(transcription)
		guard !normalized.isEmpty else { return nil }

		var best: (recipe: Recipe, triggerLen: Int, remainder: String)?

		for recipe in recipes {
			guard let trigger = recipe.triggerPhrase, !trigger.isEmpty else { continue }
			let normTrigger = normalize(trigger)
			guard !normTrigger.isEmpty else { continue }

			guard normalized.hasPrefix(normTrigger) else { continue }

			let endIndex = normalized.index(normalized.startIndex, offsetBy: normTrigger.count)
			let isWholeWord = endIndex == normalized.endIndex || normalized[endIndex] == " "
			guard isWholeWord else { continue }

			let remainder = String(normalized[endIndex...]).trimmingCharacters(in: .whitespaces)

			if best == nil || normTrigger.count > best!.triggerLen {
				best = (recipe, normTrigger.count, remainder)
			}
		}

		guard let best else { return nil }
		return RecipeMatch(recipe: best.recipe, remainingInput: best.remainder)
	}

	private static func normalize(_ s: String) -> String {
		let lowered = s.lowercased()
		let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		return collapsed.trimmingCharacters(in: .whitespaces)
	}
}

// MARK: - Orchestrator

@MainActor
@Observable
final class RecipeOrchestrator {
	private(set) var isExecuting = false
	private(set) var executingRecipeName: String?
	private(set) var lastError: String?

	let cache: RecipeCache
	private let api: WhisperaAPI

	init(api: WhisperaAPI, cache: RecipeCache) {
		self.api = api
		self.cache = cache
	}

	func processForPaste(_ transcription: String) async -> String {
		guard let match = RecipeMatcher.match(transcription, against: cache.recipes) else {
			return transcription
		}

		executingRecipeName = match.recipe.name
		isExecuting = true
		lastError = nil
		defer {
			isExecuting = false
			executingRecipeName = nil
		}

		do {
			return try await api.executeRecipe(id: match.recipe.id, input: match.remainingInput)
		} catch is CancellationError {
			AppLogger.shared.network.info("RecipeOrchestrator: execution cancelled")
			return transcription
		} catch {
			lastError = error.localizedDescription
			AppLogger.shared.network.error(
				"RecipeOrchestrator: \(match.recipe.name) failed — \(error.localizedDescription)")
			return transcription
		}
	}
}
