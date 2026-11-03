import Foundation

/// The whole sign-in flow behind two calls: `signIn()` once, `validBearer()` before
/// every backend call that needs the account.
///
/// ```swift
/// let account = AccountSignIn(
/// 	configuration: .hostedClerk(clientID: clerkClientID),
/// 	authenticator: SystemWebAuthenticator { window },
/// 	store: KeychainAccountTokenStore(service: "com.example.whispera.account"))
/// try await account.signIn()
/// let devices = try await RelayClient.devices(baseURL: backend, accountToken: try await account.validBearer())
/// ```
///
/// An actor, so concurrent `validBearer()` calls share one refresh.
public actor AccountSignIn {
	/// Nil when only a server token can be used.
	public let configuration: OIDCConfiguration?
	public let store: AccountTokenStore
	/// Refresh when the bearer has less than this left.
	public let refreshLeeway: TimeInterval
	private let authenticator: WebAuthenticator?
	private let transport: AccountHTTPTransport
	private let clock: @Sendable () -> Date
	private var discovery: OIDCDiscovery?
	private var refreshing: Task<OIDCTokens, Error>?

	public init(
		configuration: OIDCConfiguration?, authenticator: WebAuthenticator?, store: AccountTokenStore,
		transport: AccountHTTPTransport = URLSessionAccountTransport(), refreshLeeway: TimeInterval = 120,
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.configuration = configuration
		self.authenticator = authenticator
		self.store = store
		self.transport = transport
		self.refreshLeeway = refreshLeeway
		self.clock = clock
	}

	/// The stored credential, if any. Not checked for expiry.
	public var credential: AccountCredential? {
		get throws { try store.load() }
	}

	/// Discovery → authorize in the web sheet → code exchange → stored.
	/// - Parameter loginHint: optional `login_hint` (e.g. a remembered email).
	@discardableResult
	public func signIn(loginHint: String? = nil) async throws -> AccountCredential {
		guard let configuration, let authenticator else { throw AccountError.notConfigured }
		let client = OIDCClient(configuration: configuration, transport: transport, clock: clock)
		let discovery = try await client.discover()
		self.discovery = discovery
		let request = client.authorizationRequest(discovery: discovery, loginHint: loginHint)
		let callback = try await authenticator.authenticate(url: request.url, callbackScheme: configuration.callbackScheme)
		let code = try OIDCClient.authorizationCode(from: callback, for: request, issuer: discovery.issuer)
		let tokens = try await client.exchange(code: code, for: request, discovery: discovery)
		let credential = AccountCredential.oidc(tokens)
		try store.save(credential)
		return credential
	}

	/// "Use a server token": stores `token` as the credential, replacing any sign-in.
	@discardableResult
	public func useServerToken(_ token: String) throws -> AccountCredential {
		let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !token.isEmpty else { throw AccountError.notSignedIn }
		let credential = AccountCredential.staticToken(token)
		try store.save(credential)
		return credential
	}

	/// Forgets the credential on this device. (The provider session was ephemeral,
	/// so there is no browser cookie left behind.)
	public func signOut() throws {
		refreshing?.cancel()
		refreshing = nil
		try store.clear()
	}

	/// The bearer to send to the backend now, refreshed first when it has less than
	/// `refreshLeeway` left. A token with no known expiry is used until the backend
	/// refuses it — call `forceRefresh()` on that 401.
	///
	/// Throws `.notSignedIn` with no credential, `.reauthenticationRequired` when it
	/// expired and cannot be refreshed (the stored credential is then cleared), or
	/// was issued for a different issuer/client than the one configured now.
	public func validBearer() async throws -> String {
		guard let credential = try store.load() else { throw AccountError.notSignedIn }
		switch credential {
		case .staticToken(let token):
			return token
		case .oidc(let tokens):
			guard let configuration, OIDCConfiguration.sameIssuer(tokens.issuer, configuration.issuer),
			      tokens.clientID == configuration.clientID
			else { throw AccountError.reauthenticationRequired }
			let kind = configuration.backendToken
			if let bearer = tokens.bearer(kind), !isNearExpiry(tokens.expiry(of: kind)) { return bearer }
			let refreshed = try await refresh(tokens)
			guard let bearer = refreshed.bearer(kind), !isExpired(refreshed.expiry(of: kind)) else {
				throw AccountError.reauthenticationRequired
			}
			return bearer
		}
	}

	/// Refreshes now regardless of expiry — for when the backend answered 401 to a
	/// bearer this side still thought was valid. A server token is returned as is.
	public func forceRefresh() async throws -> String {
		guard let credential = try store.load() else { throw AccountError.notSignedIn }
		guard case .oidc(let tokens) = credential, let configuration else {
			return try await validBearer()
		}
		let refreshed = try await refresh(tokens)
		guard let bearer = refreshed.bearer(configuration.backendToken) else { throw AccountError.reauthenticationRequired }
		return bearer
	}

	private func isNearExpiry(_ expiry: Date?) -> Bool {
		guard let expiry else { return false }
		return expiry.timeIntervalSince(clock()) < refreshLeeway
	}

	private func isExpired(_ expiry: Date?) -> Bool {
		guard let expiry else { return false }
		return expiry <= clock()
	}

	private func refresh(_ tokens: OIDCTokens) async throws -> OIDCTokens {
		if let refreshing { return try await refreshing.value }
		guard let configuration else { throw AccountError.notConfigured }
		let task = Task { [transport, clock, discovery, store] () throws -> OIDCTokens in
			let client = OIDCClient(configuration: configuration, transport: transport, clock: clock)
			let found: OIDCDiscovery
			if let discovery {
				found = discovery
			} else {
				found = try await client.discover()
			}
			let refreshed = try await client.refresh(tokens, discovery: found)
			try store.save(.oidc(refreshed))
			return refreshed
		}
		refreshing = task
		defer { refreshing = nil }
		do {
			let refreshed = try await task.value
			return refreshed
		} catch AccountError.reauthenticationRequired {
			try? store.clear()
			throw AccountError.reauthenticationRequired
		}
	}
}
