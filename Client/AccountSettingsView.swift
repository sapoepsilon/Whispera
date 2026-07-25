// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import SwiftUI

#if canImport(ClerkKit)
import ClerkKit
import ClerkKitUI
#endif

/// Settings tab for connecting the Mac client to the Whispera backend and
/// signing in for Subscription mode. See WHI-24 / WHI-45.
struct AccountSettingsView: View {
	@State private var auth = AuthManager.shared
	@AppStorage("whisperaServerURL") private var serverURL = WhisperaSettings.defaultServerURL
	@AppStorage("whisperaClerkPublishableKey") private var clerkPublishableKey = ""
	@State private var token = ""

	var body: some View {
		let content = ScrollView {
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

						Divider()

						Text("Clerk publishable key")
							.font(.subheadline)
						TextField("pk_test_…", text: $clerkPublishableKey)
							.textFieldStyle(.roundedBorder)
							.autocorrectionDisabled()
						Text(
							"Needed to sign in with Clerk. Installed builds inherit no environment, so the key is stored here unless CLERK_PUBLISHABLE_KEY is set. Takes effect after a restart."
						)
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
		.sheet(isPresented: $auth.isClerkSheetPresented) {
			ClerkSignInSheet(auth: auth)
		}

		#if canImport(ClerkKit)
		if ClerkBridge.shared.isConfigured {
			content.environment(Clerk.shared)
		} else {
			content
		}
		#else
		content
		#endif
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
			AsyncButton("Sign in with Clerk") {
				await auth.signInWithClerk()
			}
			.buttonStyle(.borderedProminent)

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
					AsyncButton("Verify & Sign In") {
						await auth.signIn(token: token)
						if auth.isSignedIn { token = "" }
					}
					.disabled(token.isEmpty)
				}
			}
		}
	}
}

private struct ClerkSignInSheet: View {
	let auth: AuthManager

	var body: some View {
		#if canImport(ClerkKit)
		ClerkAuthView(auth: auth)
		#else
		Text("Clerk SDK is unavailable in this build.")
			.padding(24)
		#endif
	}
}

#if canImport(ClerkKit)
private struct ClerkAuthView: View {
	@Environment(Clerk.self) private var clerk
	let auth: AuthManager

	var body: some View {
		AuthView(mode: .signIn)
			.task {
				for await event in clerk.auth.events {
					switch event {
					case .sessionChanged(_, let newValue) where newValue?.status == .active:
						await auth.completeClerkSignIn()
					case .signInCompleted:
						await auth.completeClerkSignIn()
					default:
						break
					}
				}
			}
	}
}
#endif
