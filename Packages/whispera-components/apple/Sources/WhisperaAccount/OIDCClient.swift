import Foundation

/// The HTTP seam: URLSession in production, a fake in tests. `LinkTransport`
/// from WhisperaLink has the same `data(for:)` shape.
public protocol AccountHTTPTransport: Sendable {
	func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAccountTransport: AccountHTTPTransport {
	public let session: URLSession

	public init(session: URLSession = .shared) {
		self.session = session
	}

	public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
		return (data, http)
	}
}

/// One sign-in attempt: the URL to open and the secrets to check its answer with.
/// Lives only in memory for the length of the attempt.
public struct AuthorizationRequest: Equatable, Sendable {
	public let url: URL
	public let state: String
	public let nonce: String
	public let pkce: PKCE
	public let redirectURI: URL

	public init(url: URL, state: String, nonce: String, pkce: PKCE, redirectURI: URL) {
		self.url = url
		self.state = state
		self.nonce = nonce
		self.pkce = pkce
		self.redirectURI = redirectURI
	}
}

/// Authorization code + PKCE for a public client (RFC 6749, 7636; OIDC Core §3.1).
/// Stateless: every call takes what it needs, so it is safe to share.
///
/// The ID token's signature is not checked here — it came straight from the token
/// endpoint over TLS (OIDC Core §3.1.3.7 allows exactly that), and the backend that
/// accepts it as a bearer checks the signature against the JWKS. Its claims are
/// checked: `iss`, `aud`, `exp`, and `nonce` when the provider echoes one.
public struct OIDCClient: Sendable {
	public let configuration: OIDCConfiguration
	public let transport: AccountHTTPTransport
	public let clock: @Sendable () -> Date
	public static let timeout: TimeInterval = 20
	/// Tolerated clock difference when checking `exp`.
	public static let clockSkew: TimeInterval = 60

	public init(
		configuration: OIDCConfiguration, transport: AccountHTTPTransport = URLSessionAccountTransport(),
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.configuration = configuration
		self.transport = transport
		self.clock = clock
	}

	// MARK: Discovery

	/// Fetches `/.well-known/openid-configuration` and checks it names this issuer
	/// and secure endpoints.
	public func discover() async throws -> OIDCDiscovery {
		guard OIDCConfiguration.isAcceptableEndpoint(configuration.issuer) else {
			throw AccountError.insecureEndpoint(configuration.issuer.absoluteString)
		}
		var request = URLRequest(url: configuration.discoveryURL)
		request.timeoutInterval = Self.timeout
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (data, response) = try await perform(request)
		guard response.statusCode == 200 else { throw AccountError.discoveryFailed("HTTP \(response.statusCode)") }
		let discovery: OIDCDiscovery
		do {
			discovery = try JSONDecoder().decode(OIDCDiscovery.self, from: data)
		} catch {
			throw AccountError.discoveryFailed("\(error)")
		}
		guard OIDCConfiguration.sameIssuer(discovery.issuer, configuration.issuer) else {
			throw AccountError.issuerMismatch(
				expected: OIDCConfiguration.trimmed(configuration.issuer), got: discovery.issuer.absoluteString)
		}
		for endpoint in [discovery.authorization_endpoint, discovery.token_endpoint]
		where !OIDCConfiguration.isAcceptableEndpoint(endpoint) {
			throw AccountError.insecureEndpoint(endpoint.absoluteString)
		}
		return discovery
	}

	// MARK: Authorize

	/// A fresh attempt: new PKCE verifier, `state` and `nonce` (pass them only in tests).
	/// - Parameter loginHint: sent as `login_hint` (the dev IdP auto-approves with it).
	public func authorizationRequest(
		discovery: OIDCDiscovery, loginHint: String? = nil, pkce: PKCE = PKCE(),
		state: String? = nil, nonce: String? = nil
	) -> AuthorizationRequest {
		let state = state ?? OIDCRandom.base64URL(bytes: 16)
		let nonce = nonce ?? OIDCRandom.base64URL(bytes: 16)
		var items: [URLQueryItem] = [
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "client_id", value: configuration.clientID),
			URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
			URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
			URLQueryItem(name: "state", value: state),
			URLQueryItem(name: "nonce", value: nonce),
			URLQueryItem(name: "code_challenge", value: pkce.challenge),
			URLQueryItem(name: "code_challenge_method", value: PKCE.method),
		]
		if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
		let reserved = Set(items.map(\.name))
		for (name, value) in configuration.extraAuthorizeParams.sorted(by: { $0.key < $1.key }) where !reserved.contains(name) {
			items.append(URLQueryItem(name: name, value: value))
		}
		var components = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)!
		components.queryItems = (components.queryItems ?? []) + items
		// URLComponents leaves `+` alone, which form decoders read as a space.
		components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		return AuthorizationRequest(
			url: components.url!, state: state, nonce: nonce, pkce: pkce, redirectURI: configuration.redirectURI)
	}

	/// The authorization code from the provider's redirect. Checks, in order: the
	/// callback is for this redirect URI, `state` matches (also on an error answer,
	/// so a forged error is not shown), `iss` matches when present (RFC 9207),
	/// then `error`, then `code`.
	public static func authorizationCode(
		from callback: URL, for request: AuthorizationRequest, issuer: URL? = nil
	) throws -> String {
		guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
		      components.scheme?.lowercased() == request.redirectURI.scheme?.lowercased(),
		      (components.host ?? "") == (request.redirectURI.host ?? ""),
		      normalizedPath(components.path) == normalizedPath(request.redirectURI.path)
		else { throw AccountError.unexpectedCallback(callback.absoluteString) }
		var params: [String: String] = [:]
		for item in components.queryItems ?? [] where params[item.name] == nil { params[item.name] = item.value ?? "" }
		guard let state = params["state"], state == request.state else { throw AccountError.stateMismatch }
		if let iss = params["iss"], let issuer, let issURL = URL(string: iss), !OIDCConfiguration.sameIssuer(issURL, issuer) {
			throw AccountError.issuerMismatch(expected: OIDCConfiguration.trimmed(issuer), got: iss)
		}
		if let error = params["error"] {
			if error == "access_denied" && params["error_description"] == nil { throw AccountError.cancelled }
			throw AccountError.authorizationDenied(error: error, description: params["error_description"])
		}
		guard let code = params["code"], !code.isEmpty else { throw AccountError.missingAuthorizationCode }
		return code
	}

	private static func normalizedPath(_ path: String) -> String {
		var path = path
		while path.hasSuffix("/") { path.removeLast() }
		return path
	}

	// MARK: Token endpoint

	/// `grant_type=authorization_code` with the PKCE verifier.
	public func exchange(code: String, for request: AuthorizationRequest, discovery: OIDCDiscovery) async throws -> OIDCTokens {
		let response = try await tokenRequest(discovery, [
			("grant_type", "authorization_code"),
			("code", code),
			("redirect_uri", request.redirectURI.absoluteString),
			("client_id", configuration.clientID),
			("code_verifier", request.pkce.verifier),
		])
		guard let idToken = response.id_token else {
			throw AccountError.badTokenResponse("no id_token (is the openid scope allowed?)")
		}
		let claims = try validate(idToken: idToken, discovery: discovery, nonce: request.nonce)
		return tokens(from: response, idToken: idToken, claims: claims, previous: nil)
	}

	/// `grant_type=refresh_token`. A provider that rotates refresh tokens returns a
	/// new one; one that does not keeps the old. Same for the ID token.
	public func refresh(_ current: OIDCTokens, discovery: OIDCDiscovery) async throws -> OIDCTokens {
		guard let refreshToken = current.refreshToken else { throw AccountError.reauthenticationRequired }
		let response: TokenResponse
		do {
			response = try await tokenRequest(discovery, [
				("grant_type", "refresh_token"),
				("refresh_token", refreshToken),
				("client_id", configuration.clientID),
			])
		} catch AccountError.tokenRequestFailed(_, let error?, _) where error == "invalid_grant" {
			throw AccountError.reauthenticationRequired
		}
		if let idToken = response.id_token {
			let claims = try validate(idToken: idToken, discovery: discovery, nonce: nil)
			if let sub = current.subject, claims.sub != sub { throw AccountError.invalidIDToken("sub changed on refresh") }
			return tokens(from: response, idToken: idToken, claims: claims, previous: current)
		}
		return tokens(from: response, idToken: nil, claims: nil, previous: current)
	}

	struct TokenResponse: Decodable {
		var access_token: String
		var token_type: String?
		var expires_in: Double?
		var refresh_token: String?
		var id_token: String?
		var scope: String?
	}

	struct TokenErrorResponse: Decodable {
		var error: String
		var error_description: String?
	}

	private func tokenRequest(_ discovery: OIDCDiscovery, _ form: [(String, String)]) async throws -> TokenResponse {
		var request = URLRequest(url: discovery.token_endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = Self.timeout
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.httpBody = Data(Self.formEncode(form).utf8)
		let (data, response) = try await perform(request)
		guard response.statusCode == 200 else {
			let decoded = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
			throw AccountError.tokenRequestFailed(
				status: response.statusCode, error: decoded?.error, description: decoded?.error_description)
		}
		do {
			return try JSONDecoder().decode(TokenResponse.self, from: data)
		} catch {
			throw AccountError.badTokenResponse("\(error)")
		}
	}

	private func tokens(from response: TokenResponse, idToken: String?, claims: IDTokenClaims?, previous: OIDCTokens?) -> OIDCTokens {
		OIDCTokens(
			issuer: configuration.issuer,
			clientID: configuration.clientID,
			accessToken: response.access_token,
			idToken: idToken ?? previous?.idToken,
			refreshToken: response.refresh_token ?? previous?.refreshToken,
			tokenType: response.token_type ?? "Bearer",
			scope: response.scope ?? previous?.scope,
			accessTokenExpiresAt: response.expires_in.map { clock().addingTimeInterval($0) },
			idTokenExpiresAt: claims.map { Date(timeIntervalSince1970: $0.exp) } ?? previous?.idTokenExpiresAt,
			subject: claims?.sub ?? previous?.subject)
	}

	// MARK: ID token claims

	struct IDTokenClaims: Decodable {
		var iss: String
		var sub: String
		var aud: Audience
		var exp: Double
		var nonce: String?
		var azp: String?

		enum Audience: Decodable {
			case one(String)
			case many([String])

			init(from decoder: Decoder) throws {
				let container = try decoder.singleValueContainer()
				if let one = try? container.decode(String.self) {
					self = .one(one)
				} else {
					self = .many(try container.decode([String].self))
				}
			}

			func contains(_ value: String) -> Bool {
				switch self {
				case .one(let one): return one == value
				case .many(let many): return many.contains(value)
				}
			}
		}
	}

	func validate(idToken: String, discovery: OIDCDiscovery, nonce: String?) throws -> IDTokenClaims {
		let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 3, let payload = OIDCRandom.decodeBase64URL(String(parts[1])) else {
			throw AccountError.invalidIDToken("not a JWT")
		}
		let claims: IDTokenClaims
		do {
			claims = try JSONDecoder().decode(IDTokenClaims.self, from: payload)
		} catch {
			throw AccountError.invalidIDToken("claims: \(error)")
		}
		guard let iss = URL(string: claims.iss), OIDCConfiguration.sameIssuer(iss, discovery.issuer) else {
			throw AccountError.invalidIDToken("iss")
		}
		guard claims.aud.contains(configuration.clientID) else { throw AccountError.invalidIDToken("aud") }
		if case .many(let audiences) = claims.aud, audiences.count > 1, claims.azp != configuration.clientID {
			throw AccountError.invalidIDToken("azp")
		}
		guard claims.exp + Self.clockSkew > clock().timeIntervalSince1970 else { throw AccountError.invalidIDToken("expired") }
		// A provider that does not echo `nonce` is tolerated (PKCE already binds the
		// code to this attempt); one that echoes a different nonce is not.
		if let nonce, let echoed = claims.nonce, echoed != nonce { throw AccountError.invalidIDToken("nonce") }
		return claims
	}

	// MARK: Helpers

	private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		do {
			return try await transport.data(for: request)
		} catch is CancellationError {
			throw CancellationError()
		} catch let error as AccountError {
			throw error
		} catch {
			throw AccountError.transport(error.localizedDescription)
		}
	}

	/// `application/x-www-form-urlencoded`, unreserved characters only left bare.
	static func formEncode(_ pairs: [(String, String)]) -> String {
		let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
		func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
		return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
	}
}
