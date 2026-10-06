// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaBackend

/// App-level instances of the backend types.
///
/// `WhisperaBackend` deliberately ships no singletons: a package that named one
/// base URL would be unusable by any host that has a different one, and the
/// whole reason that product exists as a separate library is that a host must
/// be able to drop it. So the shared instances — and the settings key they read
/// their URL from — live here. See WHI-94.
extension WhisperaAPIClient {
	static let shared = WhisperaAPIClient(
		baseURLProvider: { WhisperaSettings.serverURL },
		credentials: BackendCredentials.shared)
}

/// The `@Observable` shell SwiftUI binds to, around the package's auth manager.
///
/// The package type is a plain `@MainActor` class: Observation is a UI concern,
/// and a package that imported it would force it on every host. Mirroring four
/// properties here is cheaper than that.
@MainActor
@Observable
final class AccountManager {
	static let shared = AccountManager()

	private(set) var isWorking = false
	private(set) var isSignedIn = false
	private(set) var displayName = "Not signed in"
	var lastError: String?

	@ObservationIgnored private let manager: AuthManager

	init(manager: AuthManager? = nil) {
		self.manager = manager ?? AuthManager(api: .shared)
		mirror()
	}

	private func mirror() {
		isWorking = manager.isWorking
		isSignedIn = manager.isSignedIn
		displayName = manager.displayName
		lastError = manager.lastError
	}

	func signIn(token: String) async {
		await manager.signIn(token: token)
		mirror()
	}

	func signInWithClerk() async {
		await manager.signInWithClerk()
		mirror()
	}

	func refresh() async {
		await manager.refresh()
		mirror()
	}

	func signOut() {
		manager.signOut()
		mirror()
	}
}
