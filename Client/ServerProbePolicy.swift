// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// When a typed server address is worth sending a request to.
///
/// Pulled out of the view so the rule is testable without a window: WHI-86's
/// acceptance is "keystrokes across an incomplete URL produce zero network
/// requests", and that is a property of this function, not of SwiftUI.
///
/// Two independent gates, both required:
///
/// 1. **Settled.** Nothing probes until the field has been quiet for
///    `debounceMilliseconds`, or the user pressed Enter or moved focus away.
///    The old code debounced the backend field by 400 ms — inside normal typing
///    cadence — and the direct field not at all.
/// 2. **Well formed.** Even settled, a value that is still missing a host, a
///    port or the `/v1` base is not a server, so it gets an inline hint and no
///    request. `192.168.50.140` produced "Could not reach 192.168.50.140 to
///    list its models" precisely because nothing checked this.
enum ServerProbePolicy {
	/// The floor WHI-86 sets. Above a comfortable inter-keystroke gap, below
	/// the pause someone takes when they have finished typing.
	static let debounceMilliseconds = 600

	static func shouldProbe(_ raw: String) -> Bool {
		ServerURLNormalizer.hint(for: raw) == nil
	}

	/// Every prefix a user passes through while typing `text`, for the
	/// regression test that none of them earn a request.
	static func typingPrefixes(of text: String) -> [String] {
		(1...max(text.count, 1)).compactMap { count in
			count <= text.count ? String(text.prefix(count)) : nil
		}
	}
}
