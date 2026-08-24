// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaBackend
import WhisperaDictation

/// The one place that knows the session token and the dictation credential are
/// related.
///
/// `WhisperaDictation` asks for a `DictationCredentialProvider` and never names
/// a token store; `WhisperaBackend` owns the Keychain-backed store. Bridging
/// them here rather than at each call site means the streaming conformer, the
/// `auto` resolver and the Settings probe all take a credential and none of
/// them import `WhisperaBackend` — which is the seam that lets a host drop that
/// product and still dictate. See WHI-94.
enum BackendCredentials {
	/// Read at connect time and dropped afterwards, and re-read on the one
	/// unauthorized retry, so a short-lived session token survives it.
	///
	/// A missing token is not fatal: a self-hosted proxy on a trusted network
	/// may require none, and refusing to connect would make the app harder to
	/// bring up than the server it talks to. A server that does want one answers
	/// 4401, which surfaces as a real error.
	static var shared: any DictationCredentialProvider { AuthTokenStore.shared.credentialProvider }

	static func provider(for store: AuthTokenStore) -> any DictationCredentialProvider {
		store.credentialProvider
	}
}
