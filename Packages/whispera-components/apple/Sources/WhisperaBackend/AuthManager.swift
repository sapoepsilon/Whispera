import Foundation

/// Owns the signed-in state.
///
/// Sign-in is required only for the backend paths — every other engine and the
/// whole recipes layer work without an account, which is why this type lives in
/// the parked package rather than in anything a dictation host must link.
@MainActor
public final class AuthManager {
	public private(set) var isWorking = false
	public private(set) var isSignedIn = false
	public private(set) var user: WhisperaUser?
	public var lastError: String?

	private let api: WhisperaAPIClient
	private let tokenStore: AuthTokenStore

	public init(api: WhisperaAPIClient, tokenStore: AuthTokenStore = .shared) {
		self.api = api
		self.tokenStore = tokenStore
	}

	public var displayName: String {
		user?.email ?? user?.name ?? user?.clerkId ?? "Signed in"
	}

	/// Saves a token and verifies it against `/auth/me`, reverting the stored
	/// token if verification fails so a bad one is never left behind.
	public func signIn(token: String) async {
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			lastError = "Enter a token first"
			return
		}

		isWorking = true
		lastError = nil
		defer { isWorking = false }

		do {
			try tokenStore.save(trimmed)
			user = try await api.getMe()
			isSignedIn = true
		} catch {
			try? tokenStore.delete()
			isSignedIn = false
			user = nil
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	/// Re-checks a stored token on launch. A 401 signs out; a network blip does
	/// not, because throwing away a good token over an offline moment would make
	/// the user sign in again for no reason.
	public func refresh() async {
		guard let token = try? tokenStore.load(), !token.isEmpty else {
			isSignedIn = false
			user = nil
			return
		}
		do {
			user = try await api.getMe()
			isSignedIn = true
		} catch WhisperaAPIError.http(let status, _) where status == 401 {
			signOut()
		} catch {
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	public func signOut() {
		try? tokenStore.delete()
		isSignedIn = false
		user = nil
		lastError = nil
	}

	/// Deliberately still a stub. Native sign-in waits for an identity app to
	/// test against, and this package is parked until backend work resumes.
	public func signInWithClerk() async {
		lastError = "Clerk sign-in isn't wired yet — use a token for now."
	}
}
