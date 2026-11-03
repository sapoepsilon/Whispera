import Foundation

/// Which OpenID Connect provider a host signs in with, and how.
///
/// The Whispera backend verifies a JWT bearer against the issuer's JWKS with
/// `aud` = `clientID`, which is what an ID token carries; `backendToken` picks
/// which of the two tokens the token endpoint returns is sent as that bearer.
public struct OIDCConfiguration: Codable, Equatable, Sendable {
	/// The token the backend is handed as `Authorization: Bearer …`.
	public enum BackendToken: String, Codable, Sendable {
		/// The ID token (a JWT whose `aud` is the client id). The default.
		case idToken
		/// The access token, for a provider that issues JWT access tokens for this API.
		case accessToken
	}

	/// The issuer, exactly as discovery reports it. HTTPS, or HTTP on loopback only.
	public var issuer: URL
	/// A public client: no secret, PKCE S256.
	public var clientID: String
	/// The custom-scheme callback registered with the provider.
	public var redirectURI: URL
	public var scopes: [String]
	public var backendToken: BackendToken
	/// Added to the authorize URL as-is (e.g. `prompt`, `ui_locales`). Never overrides
	/// a parameter this package sets.
	public var extraAuthorizeParams: [String: String]

	public init(
		issuer: URL, clientID: String, redirectURI: URL, scopes: [String] = OIDCConfiguration.defaultScopes,
		backendToken: BackendToken = .idToken, extraAuthorizeParams: [String: String] = [:]
	) {
		self.issuer = issuer
		self.clientID = clientID
		self.redirectURI = redirectURI
		self.scopes = scopes
		self.backendToken = backendToken
		self.extraAuthorizeParams = extraAuthorizeParams
	}

	/// `offline_access` asks for a refresh token, so a signed-in device stays signed in.
	public static let defaultScopes = ["openid", "profile", "email", "offline_access"]

	public static let hostedClerkIssuer = URL(string: "https://clerk.whispera.mansurov.dev")!

	/// The iPhone app's callback. Allow-listed by the dev IdP by default.
	public static let iOSRedirectURI = URL(string: "whispera://auth/callback")!
	/// The Mac app's callback.
	public static let macRedirectURI = URL(string: "whispera-mac://auth/callback")!

	/// This build's callback: `iOSRedirectURI` on iOS, `macRedirectURI` on macOS.
	public static var platformRedirectURI: URL {
		#if os(iOS)
			return iOSRedirectURI
		#else
			return macRedirectURI
		#endif
	}

	/// The hosted Whispera account (Clerk). The client id is the Clerk OAuth
	/// application's, which the host injects (build setting or Info.plist) — this
	/// package ships none.
	public static func hostedClerk(
		clientID: String, redirectURI: URL = OIDCConfiguration.platformRedirectURI
	) -> OIDCConfiguration {
		OIDCConfiguration(issuer: hostedClerkIssuer, clientID: clientID, redirectURI: redirectURI)
	}

	/// A self-hosted issuer (Keycloak, Authentik, the `whispera-dev-idp`, …).
	public static func custom(
		issuer: URL, clientID: String, redirectURI: URL = OIDCConfiguration.platformRedirectURI,
		scopes: [String] = OIDCConfiguration.defaultScopes, backendToken: BackendToken = .idToken,
		extraAuthorizeParams: [String: String] = [:]
	) -> OIDCConfiguration {
		OIDCConfiguration(
			issuer: issuer, clientID: clientID, redirectURI: redirectURI, scopes: scopes, backendToken: backendToken,
			extraAuthorizeParams: extraAuthorizeParams)
	}

	/// What `ASWebAuthenticationSession` waits for: the redirect URI's scheme.
	public var callbackScheme: String { redirectURI.scheme ?? "" }

	/// `<issuer>/.well-known/openid-configuration`.
	public var discoveryURL: URL {
		URL(string: Self.trimmed(issuer) + "/.well-known/openid-configuration")!
	}

	/// HTTPS anywhere; plain HTTP only to a loopback host (the dev IdP).
	public static func isAcceptableEndpoint(_ url: URL) -> Bool {
		switch url.scheme?.lowercased() {
		case "https": return url.host != nil
		case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
		default: return false
		}
	}

	/// Issuers compare as strings without trailing slashes (OIDC Discovery §4.3).
	static func trimmed(_ url: URL) -> String {
		var string = url.absoluteString
		while string.hasSuffix("/") { string.removeLast() }
		return string
	}

	static func sameIssuer(_ a: URL, _ b: URL) -> Bool {
		trimmed(a) == trimmed(b)
	}
}

/// The fields of an OpenID Provider's discovery document this package uses.
public struct OIDCDiscovery: Codable, Equatable, Sendable {
	public var issuer: URL
	public var authorization_endpoint: URL
	public var token_endpoint: URL
	public var jwks_uri: URL?
	public var end_session_endpoint: URL?
	public var code_challenge_methods_supported: [String]?

	public init(
		issuer: URL, authorization_endpoint: URL, token_endpoint: URL, jwks_uri: URL? = nil,
		end_session_endpoint: URL? = nil, code_challenge_methods_supported: [String]? = nil
	) {
		self.issuer = issuer
		self.authorization_endpoint = authorization_endpoint
		self.token_endpoint = token_endpoint
		self.jwks_uri = jwks_uri
		self.end_session_endpoint = end_session_endpoint
		self.code_challenge_methods_supported = code_challenge_methods_supported
	}
}
