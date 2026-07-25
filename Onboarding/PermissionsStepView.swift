import AVFoundation
import SwiftUI

struct PermissionsStepView: View {
	@Binding var hasPermissions: Bool
	@Bindable var audioManager: AudioManager
	@ObservedObject var globalShortcutManager: GlobalShortcutManager

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
		// @State does not equality-check, so writing the same value every 0.5s
		// re-evaluated this whole step twice a second
		let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
		if granted != hasMicrophonePermission {
			hasMicrophonePermission = granted
		}
	}

	private func checkAccessibilityPermission() {
		let newValue = AXIsProcessTrusted()
		if newValue != hasPermissions {
			hasPermissions = newValue
		}
	}

	private func requestMicrophonePermission() async {
		let status = AVCaptureDevice.authorizationStatus(for: .audio)
		switch status {
		case .authorized:
			AppLogger.shared.general.info("Microphone already authorized")
			checkMicrophonePermission()
		case .notDetermined:
			let granted = await AVCaptureDevice.requestAccess(for: .audio)
			if granted { checkMicrophonePermission() }
		case .denied, .restricted:
			openMicrophoneSettings()
		@unknown default:
			break
		}
	}

	private func openMicrophoneSettings() {
		if let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
		{
			NSWorkspace.shared.open(url)
		}
	}
}
