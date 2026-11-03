import Foundation

/// What the package needs in order to open a socket, expressed as transport
/// material rather than as a token string.
///
/// The indirection is the point. A token string would hard-code both the scheme
/// ("Bearer") and the carrier (a header), so moving from Clerk to Supabase, Auth0,
/// or a plain API key in a query parameter would change code inside this package.
/// Handing over headers and query items instead means the package never learns
/// which identity provider the host uses, and a provider swap is one line in the
/// host.
public struct DictationCredential: Sendable, Equatable {
	/// Applied to the HTTP upgrade request. This is where a bearer token goes: the
	/// backend reads `Authorization` off the upgrade, not off a frame.
	public var headers: [String: String]
	/// Appended to the socket URL, for providers that authenticate by query
	/// parameter. Note the backend reserves `server`, `model` and `token`.
	public var queryItems: [URLQueryItem]

	public init(headers: [String: String] = [:], queryItems: [URLQueryItem] = []) {
		self.headers = headers
		self.queryItems = queryItems
	}

	/// The common case, spelled once so no host has to remember the header name.
	public static func bearer(_ token: String) -> Self {
		Self(headers: ["Authorization": "Bearer \(token)"])
	}

	/// A credential that carries nothing — for an engine reached directly on a
	/// trusted LAN, which is how the fastest development loop runs.
	public static var none: Self { Self() }
}

extension DictationCredential: CustomStringConvertible, CustomDebugStringConvertible {
	/// Redacted on purpose.
	///
	/// The rule "never log a credential" cannot be enforced by asking callers to
	/// remember it — one `print(credential)` in a host would defeat it. Values are
	/// replaced here so that interpolating a credential anywhere, including inside
	/// this package's own error paths, cannot leak the token.
	public var description: String {
		let headerNames = headers.keys.sorted().joined(separator: ", ")
		let queryNames = queryItems.map(\.name).sorted().joined(separator: ", ")
		return "DictationCredential(headers: [\(headerNames)] redacted, query: [\(queryNames)] redacted)"
	}

	public var debugDescription: String { description }
}

/// The host's side of authentication.
///
/// Called on **every** connect rather than once at setup, because the tokens this
/// was designed around live 60 seconds. A provider that returns a cached value is
/// free to do so; one that mints a fresh token gets asked at exactly the moment a
/// fresh token is useful.
public protocol DictationCredentialProvider: Sendable {
	func credential() async throws -> DictationCredential
}

/// A fixed credential.
public struct StaticCredential: DictationCredentialProvider {
	public let value: DictationCredential

	public init(_ value: DictationCredential) { self.value = value }

	public func credential() async throws -> DictationCredential { value }
}

/// A credential the host mints on demand.
///
/// This is the Clerk shape: the closure runs on every connect and once more after
/// an unauthorized close, so a token that expired between two connects is replaced
/// without the host wiring up any refresh logic of its own.
public struct RefreshingCredential: DictationCredentialProvider {
	private let mint: @Sendable () async throws -> DictationCredential

	public init(_ mint: @escaping @Sendable () async throws -> DictationCredential) {
		self.mint = mint
	}

	public func credential() async throws -> DictationCredential { try await mint() }
}

// Sugar so the protocol only shows up when a host actually needs a custom one.
// `credentials: .bearer("…")` reads as well as it does because of these.
extension DictationCredentialProvider where Self == StaticCredential {
	public static func bearer(_ token: String) -> Self { StaticCredential(.bearer(token)) }
	public static var none: Self { StaticCredential(.none) }
	public static func fixed(_ credential: DictationCredential) -> Self { StaticCredential(credential) }
}

extension DictationCredentialProvider where Self == RefreshingCredential {
	/// Re-mint on every connect. The closure returns a token string; the header is
	/// this package's business.
	public static func refreshingBearer(
		_ mint: @escaping @Sendable () async throws -> String
	) -> Self {
		RefreshingCredential { .bearer(try await mint()) }
	}

	public static func refreshing(
		_ mint: @escaping @Sendable () async throws -> DictationCredential
	) -> Self {
		RefreshingCredential(mint)
	}
}
