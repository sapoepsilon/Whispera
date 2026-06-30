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
}
