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
	var isClerkSheetPresented = false

	private let api: WhisperaAPIClient
	private let tokenStore: AuthTokenStore
	private let clerk: ClerkSessionProviding

	init(
		api: WhisperaAPIClient = .shared,
		tokenStore: AuthTokenStore = .shared,
		clerk: ClerkSessionProviding = ClerkBridge.shared
	) {
		self.api = api
		self.tokenStore = tokenStore
		self.clerk = clerk
	}

	var displayName: String {
		user?.email ?? user?.name ?? clerk.userEmail ?? clerk.userName ?? clerk.userId ?? user?.clerkId ?? "Signed in"
	}

	/// Saves a dev token and verifies it against /auth/me. This hidden shortcut
	/// keeps WHI-41/42 development unblocked while the real Clerk app is wired.
	func signIn(token: String) async {
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			lastError = "Enter a token first"
			return
		}

		await verifyAndPersist(token: trimmed)
	}

	func signInWithClerk() async {
		isWorking = true
		lastError = nil
		defer { isWorking = false }

		do {
			try await clerk.load()
			if clerk.hasActiveSession {
				try await persistCurrentClerkToken()
			} else {
				isClerkSheetPresented = true
			}
		} catch {
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	/// Called by the Clerk sheet/auth event listener after a native Clerk flow
	/// creates or recovers an active session.
	func completeClerkSignIn() async {
		isWorking = true
		lastError = nil
		defer { isWorking = false }

		do {
			try await persistCurrentClerkToken()
			isClerkSheetPresented = false
		} catch {
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
		Task { try? await clerk.signOut() }
		try? tokenStore.delete()
		isSignedIn = false
		user = nil
		lastError = nil
		isClerkSheetPresented = false
	}

	private func persistCurrentClerkToken() async throws {
		guard let token = try await clerk.sessionToken(), !token.isEmpty else {
			throw ClerkBridgeError.noActiveSession
		}
		await verifyAndPersist(token: token)
	}

	private func verifyAndPersist(token: String) async {
		lastError = nil
		do {
			try tokenStore.save(token)
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
}
