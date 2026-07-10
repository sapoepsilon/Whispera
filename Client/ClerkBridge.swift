// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

#if canImport(ClerkKit)
import ClerkKit
#endif

/// Small adapter around Clerk's Swift SDK so the rest of the client can be
/// tested without importing ClerkKit directly. Clerk's package supports native
/// macOS targets, so WHI-45 uses the native SDK path rather than a WebView.
@MainActor
protocol ClerkSessionProviding: AnyObject {
	var userEmail: String? { get }
	var userName: String? { get }
	var userId: String? { get }
	var hasActiveSession: Bool { get }

	func load() async throws
	func sessionToken() async throws -> String?
	func signOut() async throws
}

@MainActor
final class ClerkBridge: ClerkSessionProviding {
	static let shared = ClerkBridge()

	private(set) var isConfigured = false

	var userEmail: String? {
		#if canImport(ClerkKit)
		return Clerk.shared.user?.primaryEmailAddress?.emailAddress
		#else
		return nil
		#endif
	}

	var userName: String? {
		#if canImport(ClerkKit)
		let user = Clerk.shared.user
		return [user?.firstName, user?.lastName]
			.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
		#else
		return nil
		#endif
	}

	var userId: String? {
		#if canImport(ClerkKit)
		return Clerk.shared.user?.id
		#else
		return nil
		#endif
	}

	var hasActiveSession: Bool {
		#if canImport(ClerkKit)
		return Clerk.shared.session != nil
		#else
		return false
		#endif
	}

	func configureIfPossible() {
		guard !isConfigured else { return }
		guard let publishableKey = WhisperaSettings.clerkPublishableKey, !publishableKey.isEmpty else {
			return
		}

		#if canImport(ClerkKit)
		Clerk.configure(publishableKey: publishableKey)
		isConfigured = true
		#endif
	}

	func load() async throws {
		#if canImport(ClerkKit)
		configureIfPossible()
		guard isConfigured else { throw ClerkBridgeError.missingPublishableKey }
		_ = try await Clerk.shared.refreshEnvironment()
		_ = try await Clerk.shared.refreshClient()
		#endif
	}

	func handle(_ url: URL) async throws {
		#if canImport(ClerkKit)
		configureIfPossible()
		guard isConfigured else { throw ClerkBridgeError.missingPublishableKey }
		try await Clerk.shared.handle(url)
		#endif
	}

	func sessionToken() async throws -> String? {
		#if canImport(ClerkKit)
		try await load()
		return try await Clerk.shared.auth.getToken()
		#else
		return nil
		#endif
	}

	func signOut() async throws {
		#if canImport(ClerkKit)
		configureIfPossible()
		guard isConfigured else { return }
		try await Clerk.shared.auth.signOut()
		#endif
	}
}

enum ClerkBridgeError: LocalizedError {
	case missingPublishableKey
	case noActiveSession

	var errorDescription: String? {
		switch self {
		case .missingPublishableKey:
			return "Set CLERK_PUBLISHABLE_KEY in the app environment before using Clerk sign-in."
		case .noActiveSession:
			return "No active Clerk session"
		}
	}
}
