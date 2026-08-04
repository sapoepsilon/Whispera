// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

/// Owns the signed-in state for Subscription mode. Sign-in is required ONLY for
/// Subscription mode — Local and BYOK modes work without an account. See WHI-45.
@MainActor
@Observable
final class AuthManager {
	static let shared = AuthManager()

	private(set) var isWorking = false
	private(set) var isSignedIn = false
	private(set) var user: WhisperaUser?
	var lastError: String?

	private let api: WhisperaAPIClient
	private let tokenStore: AuthTokenStore

	init(api: WhisperaAPIClient = .shared, tokenStore: AuthTokenStore = .shared) {
		self.api = api
		self.tokenStore = tokenStore
	}

	var displayName: String {
		user?.email ?? user?.name ?? user?.clerkId ?? "Signed in"
	}

	/// Saves a token (Clerk JWT or dev token) and verifies it against /auth/me.
	/// Reverts the stored token if verification fails so we never persist a bad one.
	func signIn(token: String) async {
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
			let me = try await api.getMe()
			user = me
			isSignedIn = true
		} catch {
			try? tokenStore.delete()
			isSignedIn = false
			user = nil
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	/// Re-checks an existing stored token on launch. Silently signs out on 401.
	func refresh() async {
		guard let token = try? tokenStore.load(), !token.isEmpty else {
			isSignedIn = false
			user = nil
			return
		}
		_ = token
		do {
			user = try await api.getMe()
			isSignedIn = true
		} catch WhisperaAPIError.http(let status, _) where status == 401 {
			signOut()
		} catch {
			// Network blip — keep the stored token, just report unknown status.
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	func signOut() {
		try? tokenStore.delete()
		isSignedIn = false
		user = nil
		lastError = nil
	}

	// ponytail: native Clerk sign-in (Clerk Swift SDK / hosted WebView) is deferred
	// until a Clerk app + publishable key exist to test against. The dev-token path
	// above covers Subscription-mode development today (backend NODE_ENV=test). WHI-45.
	func signInWithClerk() async {
		lastError = "Clerk sign-in isn't wired yet — use a token for now."
	}
}
