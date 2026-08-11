// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// A dictation failure the user has to do something about.
///
/// Separate from the status line in the HUD, which is one line of state and has
/// no room to explain anything. This is what an `.alert()` presents, so every
/// message names the thing that failed and what to check. "InternalServerError"
/// is not a message; "Whispera could not reach 192.168.50.140. Check that the
/// server is running" is.
struct TranscriptionFailure: Identifiable, Equatable {
	let id = UUID()
	let title: String
	let message: String

	static func == (lhs: TranscriptionFailure, rhs: TranscriptionFailure) -> Bool {
		lhs.title == rhs.title && lhs.message == rhs.message
	}
}

extension Notification.Name {
	/// A dictation failed in a way the user has to act on. The app brings up
	/// Settings, which is both where the alert is presented and where every one of
	/// these failures is fixed.
	static let transcriptionFailureRaised = Notification.Name("TranscriptionFailureRaised")
}
