// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// App-global client settings backed by UserDefaults. Secrets (auth token,
/// BYOK keys) never live here — they go in the Keychain. See WHI-24/40/45.
enum WhisperaSettings {
	private static let defaults = UserDefaults.standard
	private static let serverURLKey = "whisperaServerURL"

	static let defaultServerURL = "http://localhost:3000"

	static var serverURLString: String {
		get { defaults.string(forKey: serverURLKey) ?? defaultServerURL }
		set { defaults.set(newValue, forKey: serverURLKey) }
	}

	static var serverURL: URL? {
		URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	private static let clerkPublishableKeyKey = "whisperaClerkPublishableKey"

	/// Clerk publishable key is deployment config, not a secret, so it lives here
	/// rather than the Keychain. The process environment wins so an Xcode scheme
	/// can override per-run, but a stored value is required for installed builds:
	/// a double-clicked .app inherits no environment, so an env-only key would
	/// leave Clerk silently unconfigured. See WHI-45.
	static var clerkPublishableKey: String? {
		get {
			let env = ProcessInfo.processInfo.environment["CLERK_PUBLISHABLE_KEY"]?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if let env, !env.isEmpty { return env }

			let stored = defaults.string(forKey: clerkPublishableKeyKey)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let stored, !stored.isEmpty else { return nil }
			return stored
		}
		set { defaults.set(newValue, forKey: clerkPublishableKeyKey) }
	}

	private static let defaultCommandIdKey = "whisperaDefaultCommandId"

	/// Recipe id of the command that post-processes every dictation when no
	/// trigger phrase matches. Empty = no default (paste raw). See WHI-49.
	static var defaultCommandId: String {
		get { defaults.string(forKey: defaultCommandIdKey) ?? "" }
		set { defaults.set(newValue, forKey: defaultCommandIdKey) }
	}
}
