import AVFoundation
import SwiftUI

struct PermissionsStepView: View {
	@Binding var hasPermissions: Bool
	@Bindable var audioManager: AudioManager
	@ObservedObject var globalShortcutManager: GlobalShortcutManager

	@State private var hasMicrophonePermission = false
	@State private var showRows = [false, false]
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
				Group {
					PermissionRowView(
						icon: "key.fill",
						title: "Accessibility Access",
						description: "Required for global keyboard shortcuts",
						isGranted: hasPermissions
					)

					if !hasPermissions {
						Button("Grant Accessibility Access") {
							globalShortcutManager.requestAccessibilityPermissions()
						}
						.controlSize(.small)
					}
				}
				.opacity(showRows[0] ? 1 : 0)
				.offset(x: showRows[0] ? 0 : 30)

				Group {
					PermissionRowView(
						icon: "mic.fill",
						title: "Microphone Access",
						description: "Required for voice recording",
						isGranted: hasMicrophonePermission
					)

					if !hasMicrophonePermission {
						Button("Grant Microphone Access") {
							Task { await requestMicrophonePermission() }
						}
						.controlSize(.small)
					}
				}
				.opacity(showRows[1] ? 1 : 0)
				.offset(x: showRows[1] ? 0 : 30)
			}

			if hasPermissions && hasMicrophonePermission {
				HStack(spacing: 8) {
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(.green)
					Text("All permissions granted!")
						.font(.subheadline)
						.foregroundColor(.green)
				}
				.padding()
				.background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
				.transition(.scale.combined(with: .opacity))
			} else {
				VStack(spacing: 8) {
					if !hasPermissions {
						Text(
							"Go to System Settings > Privacy & Security > Accessibility and enable Whispera."
						)
						.font(.subheadline)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
					}
					if !hasMicrophonePermission {
						Text(
							"Microphone access will be requested when you click the button above."
						)
						.font(.subheadline)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
					}
				}
				.padding()
				.background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
			}
		}
		.animation(.spring(duration: 0.4, bounce: 0.15), value: hasPermissions)
		.animation(.spring(duration: 0.4, bounce: 0.15), value: hasMicrophonePermission)
		.onAppear {
			checkAccessibilityPermission()
			checkMicrophonePermission()
			animateRowsIn()
		}
		.onReceive(permissionTimer) { _ in
			checkAccessibilityPermission()
			checkMicrophonePermission()
		}
	}

	private func animateRowsIn() {
		for i in 0..<2 {
			withAnimation(.spring(duration: 0.4, bounce: 0.15).delay(Double(i) * 0.1)) {
				showRows[i] = true
			}
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
