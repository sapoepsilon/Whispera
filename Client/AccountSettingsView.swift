// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

/// Settings tab for connecting the Mac client to the Whispera backend and
/// signing in for Subscription mode. See WHI-24 / WHI-45.
struct AccountSettingsView: View {
	@State private var auth = AuthManager.shared
	@AppStorage("whisperaServerURL") private var serverURL = WhisperaSettings.defaultServerURL
	@State private var token = ""

	var body: some View {
		ScrollView {
			VStack(spacing: 24) {
				SettingsSection("Whispera Server") {
					VStack(alignment: .leading, spacing: 8) {
						Text("Server URL")
							.font(.subheadline)
						TextField(WhisperaSettings.defaultServerURL, text: $serverURL)
							.textFieldStyle(.roundedBorder)
							.autocorrectionDisabled()
						Text("Used for Subscription and BYOK recipe execution. Local mode needs no server.")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}

				SettingsSection("Account") {
					if auth.isSignedIn {
						signedInView
					} else {
						signedOutView
					}

					if let error = auth.lastError {
						Text(error)
							.font(.caption)
							.foregroundColor(.red)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
			}
			.padding(20)
		}
		.task { await auth.refresh() }
	}

	private var signedInView: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text("Signed in as")
					.font(.caption)
					.foregroundColor(.secondary)
				Text(auth.displayName)
					.font(.headline)
			}
			Spacer()
			Button("Sign Out") { auth.signOut() }
		}
	}

	private var signedOutView: some View {
		VStack(alignment: .leading, spacing: 12) {
			Button {
				Task { await auth.signInWithClerk() }
			} label: {
				Label("Sign in with Clerk", systemImage: "person.crop.circle")
			}
			.buttonStyle(.borderedProminent)
			.disabled(auth.isWorking)

			Divider()

			VStack(alignment: .leading, spacing: 6) {
				Text("Developer token")
					.font(.subheadline)
				Text("Paste a Clerk session token, or any opaque token when the backend runs in test mode.")
					.font(.caption)
					.foregroundColor(.secondary)
				HStack {
					SecureField("token", text: $token)
						.textFieldStyle(.roundedBorder)
					Button("Verify & Sign In") {
						Task {
							await auth.signIn(token: token)
							if auth.isSignedIn { token = "" }
						}
					}
					.disabled(auth.isWorking || token.isEmpty)
				}
				if auth.isWorking {
					ProgressView().scaleEffect(0.7)
				}
			}
		}
	}
}
