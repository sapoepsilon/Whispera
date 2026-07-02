import AVFoundation
import SwiftUI

struct PermissionsStepView: View {
	@Binding var hasPermissions: Bool
	@Bindable var audioManager: AudioManager
	@ObservedObject var globalShortcutManager: GlobalShortcutManager
	@State private var permissionManager = PermissionManager()
	@State private var hasMicrophonePermission = false
	private let permissionTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 8) {
				Image(systemName: "lock.shield.fill")
					.font(.system(size: 36))
					.foregroundColor(.orange)

				Text("Permissions Required")
					.font(.system(.title2, design: .rounded, weight: .bold))

				Text(
					"Whispera needs these permissions to work with global shortcuts and record audio."
				)
				.font(.body)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			}

			VStack(spacing: 16) {
				PermissionRowView(
					icon: "key.fill",
					title: "Accessibility Access",
					description: "Required for global keyboard shortcuts",
					isGranted: hasPermissions,
					grantAction: {
						globalShortcutManager.requestAccessibilityPermissions()
					}
				)

				Divider()

				PermissionRowView(
					icon: "mic.fill",
					title: "Microphone Access",
					description: "Required for voice recording",
					isGranted: hasMicrophonePermission,
					grantAction: {
						Task { await requestMicrophonePermission() }
					}
				)
			}
			.padding(16)
			.background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

			Group {
				if hasPermissions && hasMicrophonePermission {
					HStack(spacing: 8) {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.green)
						Text("All permissions granted!")
							.font(.subheadline)
							.foregroundColor(.green)
					}
					.transition(.scale.combined(with: .opacity))
				} else if !hasPermissions {
					Text(
						"Go to System Settings > Privacy & Security > Accessibility and enable Whispera."
					)
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
				}
			}
			.frame(minHeight: 40)
		}
		.animation(.spring(duration: 0.4, bounce: 0.15), value: hasPermissions)
		.animation(.spring(duration: 0.4, bounce: 0.15), value: hasMicrophonePermission)
		.onAppear {
			var transaction = Transaction()
			transaction.disablesAnimations = true
			withTransaction(transaction) {
				checkAccessibilityPermission()
				checkMicrophonePermission()
			}
		}
		.onReceive(permissionTimer) { _ in
			checkAccessibilityPermission()
			checkMicrophonePermission()
		}
	}

	private func checkMicrophonePermission() {
		hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
	}

	private func checkAccessibilityPermission() {
		let newValue = AXIsProcessTrusted()
		if newValue != hasPermissions {
			hasPermissions = newValue
		}
	}

	// Shared prompt-first flow (same as Settings) — see PermissionManager, WHI-52.
	// PermissionManager.requestMicrophoneAccess() owns the status switch: prompts
	// when undetermined, opens the Microphone pane when previously denied.
	private func requestMicrophonePermission() async {
		if await permissionManager.requestMicrophoneAccess() {
			checkMicrophonePermission()
		}
	}
}
