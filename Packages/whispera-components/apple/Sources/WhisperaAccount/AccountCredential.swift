import Foundation

/// What a token endpoint returned, plus when each token stops being usable.
public struct OIDCTokens: Codable, Equatable, Sendable {
	/// The issuer these tokens came from; a credential from another issuer is not reused.
	public var issuer: URL
	public var clientID: String
	public var accessToken: String
	public var idToken: String?
	public var refreshToken: String?
	public var tokenType: String
	public var scope: String?
	/// From `expires_in`, when the provider sent one.
	public var accessTokenExpiresAt: Date?
	/// The ID token's `exp` claim.
	public var idTokenExpiresAt: Date?
	/// The ID token's `sub` — the account, as the backend will see it.
	public var subject: String?

	public init(
		issuer: URL, clientID: String, accessToken: String, idToken: String? = nil, refreshToken: String? = nil,
		tokenType: String = "Bearer", scope: String? = nil, accessTokenExpiresAt: Date? = nil,
		idTokenExpiresAt: Date? = nil, subject: String? = nil
	) {
		self.issuer = issuer
		self.clientID = clientID
		self.accessToken = accessToken
		self.idToken = idToken
		self.refreshToken = refreshToken
		self.tokenType = tokenType
		self.scope = scope
		self.accessTokenExpiresAt = accessTokenExpiresAt
		self.idTokenExpiresAt = idTokenExpiresAt
		self.subject = subject
	}

	/// The token sent to the backend for `kind`; nil when the provider issued none.
	public func bearer(_ kind: OIDCConfiguration.BackendToken) -> String? {
		switch kind {
		case .idToken: return idToken
		case .accessToken: return accessToken
		}
	}

	/// When the token `bearer(kind)` returns expires; nil if unknown.
	public func expiry(of kind: OIDCConfiguration.BackendToken) -> Date? {
		switch kind {
		case .idToken: return idTokenExpiresAt
		case .accessToken: return accessTokenExpiresAt
		}
	}
}

/// How a device proves which account it belongs to.
public enum AccountCredential: Codable, Equatable, Sendable {
	/// Signed in through an OpenID Connect provider (hosted or self-hosted).
	case oidc(OIDCTokens)
	/// "Use a server token": a self-hoster pastes a long-lived token their server
	/// accepts. Never refreshed, never expires on this side.
	case staticToken(String)

	/// The bearer for the backend, with no expiry check. Prefer
	/// `AccountSignIn.validBearer()`, which refreshes first.
	public func bearer(_ kind: OIDCConfiguration.BackendToken) -> String? {
		switch self {
		case .oidc(let tokens): return tokens.bearer(kind)
		case .staticToken(let token): return token
		}
	}

	public var isStaticToken: Bool {
		if case .staticToken = self { return true }
		return false
	}

	/// The OIDC `sub`, when known.
	public var subject: String? {
		if case .oidc(let tokens) = self { return tokens.subject }
		return nil
	}
}

public enum AccountError: Error, Equatable, Sendable, LocalizedError {
	case invalidPKCEVerifier
	/// The issuer, or an endpoint discovery returned, is neither HTTPS nor loopback HTTP.
	case insecureEndpoint(String)
	case discoveryFailed(String)
	/// Discovery's `issuer` is not the configured one.
	case issuerMismatch(expected: String, got: String)
	/// The callback's `state` is missing or not the one this attempt sent.
	case stateMismatch
	/// The callback is not for this attempt's redirect URI.
	case unexpectedCallback(String)
	/// The provider answered the authorize request with `error=…`.
	case authorizationDenied(error: String, description: String?)
	case missingAuthorizationCode
	/// The token endpoint refused (`error`, `error_description` when it sent them).
	case tokenRequestFailed(status: Int, error: String?, description: String?)
	case badTokenResponse(String)
	/// The ID token's `iss`, `aud`, `nonce` or `exp` is wrong.
	case invalidIDToken(String)
	/// The user closed the sign-in sheet.
	case cancelled
	case notSignedIn
	/// No configuration to sign in with (only a server token can be used).
	case notConfigured
	/// The credential expired and cannot be refreshed: sign in again.
	case reauthenticationRequired
	case keychain(Int32)
	case transport(String)

	public var errorDescription: String? {
		switch self {
		case .invalidPKCEVerifier: return "Invalid PKCE verifier."
		case .insecureEndpoint(let url): return "Sign-in endpoints must use HTTPS: \(url)"
		case .discoveryFailed(let detail): return "Couldn't read the sign-in provider's configuration: \(detail)"
		case .issuerMismatch(let expected, let got): return "The sign-in provider says it is \(got), not \(expected)."
		case .stateMismatch: return "The sign-in response didn't match this sign-in attempt."
		case .unexpectedCallback(let url): return "Unexpected sign-in callback: \(url)"
		case .authorizationDenied(let error, let description): return description ?? "Sign-in was refused (\(error))."
		case .missingAuthorizationCode: return "The sign-in response had no authorization code."
		case .tokenRequestFailed(let status, let error, let description):
			return description ?? "The sign-in provider refused the token request (\(error ?? "HTTP \(status)"))."
		case .badTokenResponse(let detail): return "Unexpected token response: \(detail)"
		case .invalidIDToken(let detail): return "The sign-in provider's ID token is invalid: \(detail)"
		case .cancelled: return "Sign-in was cancelled."
		case .notSignedIn: return "Not signed in."
		case .notConfigured: return "No sign-in provider is configured."
		case .reauthenticationRequired: return "Your session expired. Sign in again."
		case .keychain(let status): return "Keychain error \(status)."
		case .transport(let detail): return "Couldn't reach the sign-in provider: \(detail)"
		}
	}
}
