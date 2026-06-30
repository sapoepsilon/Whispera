// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

struct WhisperaUser: Decodable, Sendable, Equatable {
	let id: String
	let clerkId: String
	let email: String?
	let name: String?
}

enum WhisperaAPIError: LocalizedError {
	case invalidServerURL
	case notAuthenticated
	case http(status: Int, body: String)
	case empty
	case transport(Error)

	var errorDescription: String? {
		switch self {
		case .invalidServerURL: return "Invalid Whispera server URL"
		case .notAuthenticated: return "Not signed in"
		case .http(let status, let body):
			return "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
		case .empty: return "Server returned an empty response"
		case .transport(let err): return "Network error: \(err.localizedDescription)"
		}
	}
}

/// Thin HTTP client for the Whispera backend.
///
/// The auth token and any BYOK provider key are read from the Keychain at
/// request time and never cached on the instance. The base URL is read from
/// `WhisperaSettings` per request so a settings change takes effect immediately.
struct WhisperaAPIClient {
	static let shared = WhisperaAPIClient()

	private let session: URLSession
	private let tokenStore: AuthTokenStore
	private let serverURLProvider: () -> URL?

	private let encoder: JSONEncoder = {
		let e = JSONEncoder()
		return e
	}()
	private let decoder: JSONDecoder = {
		let d = JSONDecoder()
		return d
	}()

	init(
		session: URLSession = .shared,
		tokenStore: AuthTokenStore = .shared,
		serverURLProvider: @escaping () -> URL? = { WhisperaSettings.serverURL }
	) {
		self.session = session
		self.tokenStore = tokenStore
		self.serverURLProvider = serverURLProvider
	}

	// MARK: - Endpoints

	func getMe() async throws -> WhisperaUser {
		try await get("/auth/me")
	}

	// MARK: - Generic verbs (reused by later PRs)

	func get<T: Decodable>(_ path: String, providerKey: String? = nil) async throws -> T {
		let data = try await perform(path: path, method: "GET", body: Optional<Data>.none, providerKey: providerKey)
		return try decode(data)
	}

	func send<B: Encodable, T: Decodable>(
		_ path: String, method: String, body: B, providerKey: String? = nil
	) async throws -> T {
		let data = try await perform(
			path: path, method: method, body: try encoder.encode(body), providerKey: providerKey)
		return try decode(data)
	}

	/// For requests whose response body we don't care about (e.g. DELETE 204).
	func sendNoContent<B: Encodable>(
		_ path: String, method: String, body: B?, providerKey: String? = nil
	) async throws {
		let encoded = try body.map { try encoder.encode($0) }
		_ = try await perform(path: path, method: method, body: encoded, providerKey: providerKey)
	}

	// MARK: - Core

	@discardableResult
	private func perform(
		path: String, method: String, body: Data?, providerKey: String?
	) async throws -> Data {
		guard let base = serverURLProvider() else { throw WhisperaAPIError.invalidServerURL }
		guard let token = try? tokenStore.load(), !token.isEmpty else {
			throw WhisperaAPIError.notAuthenticated
		}

		var request = URLRequest(url: base.appendingPathComponent(path))
		request.httpMethod = method
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = body
		}
		if let providerKey, !providerKey.isEmpty {
			request.setValue(providerKey, forHTTPHeaderField: "X-Provider-Key")
		}

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			throw WhisperaAPIError.transport(error)
		}

		guard let http = response as? HTTPURLResponse else { throw WhisperaAPIError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw WhisperaAPIError.http(
				status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}
		return data
	}

	private func decode<T: Decodable>(_ data: Data) throws -> T {
		if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
		guard !data.isEmpty else { throw WhisperaAPIError.empty }
		return try decoder.decode(T.self, from: data)
	}
}

struct EmptyResponse: Decodable {}
