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

	/// Clerk publishable key: deployment config, not a secret, and not something
	/// a user should ever be asked for. It ships in Info.plist so installed
	/// builds work — a double-clicked .app inherits no process environment, so
	/// an env-only key left Clerk silently unconfigured. The environment still
	/// wins so a dev build can point at another Clerk instance. See WHI-45.
	static var clerkPublishableKey: String? {
		let env = ProcessInfo.processInfo.environment["CLERK_PUBLISHABLE_KEY"]?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if let env, !env.isEmpty { return env }

		let bundled = (Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let bundled, !bundled.isEmpty else { return nil }
		return bundled
	}

	private static let defaultCommandIdKey = "whisperaDefaultCommandId"

	/// Recipe id of the command that post-processes every dictation when no
	/// trigger phrase matches. Empty = no default (paste raw). See WHI-49.
	static var defaultCommandId: String {
		get { defaults.string(forKey: defaultCommandIdKey) ?? "" }
		set { defaults.set(newValue, forKey: defaultCommandIdKey) }
	}
}
