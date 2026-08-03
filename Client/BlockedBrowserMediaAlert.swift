// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit

/// The modal that explains why a browser kept playing through a dictation.
///
/// A modal rather than a line in the pill: this is a one-off permission the user
/// has to go and grant in another application, and an overlay that fades after a
/// few seconds is gone whether or not it was read. `MediaPlaybackCoordinator`
/// reports each browser once per run, so the modal cannot become a nag.
@MainActor
enum BlockedBrowserMediaAlert {
	static var isSuppressed: Bool { WhisperaSettings.suppressBlockedBrowserMediaAlert }

	/// Returns `false` only when the alert could not be put up right now, so the
	/// caller can hold the message and retry after the next dictation. A browser
	/// is announced once per run, and a swallowed alert would spend that one
	/// chance on nothing.
	@discardableResult
	static func present(message: String) -> Bool {
		guard !message.isEmpty else { return true }
		guard !isSuppressed else { return true }
		// A second `runModal` nests another run loop under the first; the alert
		// would be stacked on top of whatever the user is already answering.
		guard NSApp.modalWindow == nil else {
			AppLogger.shared.audioManager.info(
				"Holding the blocked browser media alert — another modal is up")
			return false
		}

		let alert = NSAlert()
		alert.messageText = "Let Whispera pause your browser media"
		alert.informativeText = message
		alert.alertStyle = .informational
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Don't Show Again")

		// Whispera is an accessory app: with no front window of its own the alert
		// opens behind whatever the user is looking at unless we activate first.
		NSApp.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertSecondButtonReturn {
			WhisperaSettings.suppressBlockedBrowserMediaAlert = true
			AppLogger.shared.audioManager.info(
				"Suppressing the blocked browser media alert at the user's request")
		}
		return true
	}
}
