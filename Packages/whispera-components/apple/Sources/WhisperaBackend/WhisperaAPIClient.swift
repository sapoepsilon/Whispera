import Foundation
import WhisperaDictation
import WhisperaRecipes

public struct WhisperaUser: Decodable, Sendable, Equatable {
	public let id: String
	public let clerkId: String
	public let email: String?
	public let name: String?
}

public enum WhisperaAPIError: LocalizedError, Equatable {
	case invalidServerURL
	case notAuthenticated
	case http(status: Int, body: String)
	case empty
	case transport(String)

	public var errorDescription: String? {
		switch self {
		case .invalidServerURL: return "Invalid Whispera server URL"
		case .notAuthenticated: return "Not signed in"
		case .http(let status, let body):
			return "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
		case .empty: return "Server returned an empty response"
		case .transport(let detail): return "Network error: \(detail)"
		}
	}
}

public struct EmptyResponse: Decodable, Sendable {
	public init() {}
}

/// Thin HTTP client for the Whispera backend.
///
/// Credentials come from a `DictationCredentialProvider` rather than a token
/// store, which is what lets this package be removed without the dictation and
/// batch paths losing their auth — they never depended on this type, only on
/// something that could produce a header.
public struct WhisperaAPIClient: Sendable {
	private let session: URLSession
	private let credentials: any DictationCredentialProvider
	private let baseURLProvider: @Sendable () -> URL?

	public init(
		baseURL: URL,
		credentials: any DictationCredentialProvider,
		session: URLSession = .shared
	) {
		self.init(
			baseURLProvider: { baseURL }, credentials: credentials, session: session)
	}

	/// The base URL as a closure, so a settings change takes effect on the next
	/// request instead of on the next launch.
	public init(
		baseURLProvider: @escaping @Sendable () -> URL?,
		credentials: any DictationCredentialProvider,
		session: URLSession = .shared
	) {
		self.baseURLProvider = baseURLProvider
		self.credentials = credentials
		self.session = session
	}

	// MARK: - Endpoints

	public func getMe() async throws -> WhisperaUser {
		try await get("/auth/me")
	}

	// MARK: - Generic verbs

	public func get<T: Decodable>(_ path: String, providerKey: String? = nil) async throws -> T {
		let data = try await perform(
			path: path, method: "GET", body: nil, providerKey: providerKey)
		return try decode(data)
	}

	public func send<B: Encodable, T: Decodable>(
		_ path: String, method: String, body: B, providerKey: String? = nil
	) async throws -> T {
		let data = try await perform(
			path: path, method: method, body: try JSONEncoder().encode(body),
			providerKey: providerKey)
		return try decode(data)
	}

	/// For requests whose response body nothing reads (a DELETE answering 204).
	public func sendNoContent<B: Encodable>(
		_ path: String, method: String, body: B?, providerKey: String? = nil
	) async throws {
		let encoded = try body.map { try JSONEncoder().encode($0) }
		_ = try await perform(
			path: path, method: method, body: encoded, providerKey: providerKey)
	}

	// MARK: - Core

	@discardableResult
	func perform(
		path: String, method: String, body: Data?, providerKey: String?
	) async throws -> Data {
		var request = try await authorizedRequest(path: path, method: method)
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = body
		}
		if let providerKey, !providerKey.isEmpty {
			request.setValue(providerKey, forHTTPHeaderField: "X-Provider-Key")
		}
		return try await execute(request)
	}

	/// String join rather than `appendingPathComponent`, so a query string like
	/// "/recipes?limit=100" is not percent-encoded into the path.
	func url(for path: String) throws -> URL {
		guard let base = baseURLProvider() else { throw WhisperaAPIError.invalidServerURL }
		let trimmed =
			base.absoluteString.hasSuffix("/")
			? String(base.absoluteString.dropLast()) : base.absoluteString
		let fullPath = path.hasPrefix("/") ? path : "/" + path
		guard let url = URL(string: trimmed + fullPath) else {
			throw WhisperaAPIError.invalidServerURL
		}
		return url
	}

	func authorizedRequest(path: String, method: String) async throws -> URLRequest {
		var url = try url(for: path)
		let credential = try await credentials.credential()

		if !credential.queryItems.isEmpty,
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		{
			components.queryItems = (components.queryItems ?? []) + credential.queryItems
			guard let combined = components.url else { throw WhisperaAPIError.invalidServerURL }
			url = combined
		}

		guard !credential.headers.isEmpty else { throw WhisperaAPIError.notAuthenticated }

		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		for (name, value) in credential.headers { request.setValue(value, forHTTPHeaderField: name) }
		return request
	}

	func execute(_ request: URLRequest) async throws -> Data {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch {
			throw WhisperaAPIError.transport(error.localizedDescription)
		}

		guard let http = response as? HTTPURLResponse else { throw WhisperaAPIError.empty }
		guard (200..<300).contains(http.statusCode) else {
			throw WhisperaAPIError.http(
				status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
		}
		return data
	}

	func decode<T: Decodable>(_ data: Data) throws -> T {
		if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
		guard !data.isEmpty else { throw WhisperaAPIError.empty }
		return try JSONDecoder().decode(T.self, from: data)
	}
}
