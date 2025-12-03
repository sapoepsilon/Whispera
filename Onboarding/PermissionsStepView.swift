import AVFoundation
//
//  PermissionsStepView.swift
//  Whispera
//
//  Created by Varkhuman Mac on 7/4/25.
//
import SwiftUI

struct PermissionsStepView: View {
	@Binding var hasPermissions: Bool
	@Bindable var audioManager: AudioManager
	@ObservedObject var globalShortcutManager: GlobalShortcutManager
	@State private var hasMicrophonePermission = false
	@State private var permissionCheckTimer: Timer?
	@State private var accessibilityCheckTimer: Timer?

	var body: some View {
		VStack(spacing: 24) {
			VStack(spacing: 16) {
				Image(systemName: "lock.shield.fill")
					.font(.system(size: 48))
					.foregroundColor(.orange)

				Text("Permissions Required")
					.font(.system(.title, design: .rounded, weight: .semibold))

				Text("Whispera needs accessibility permissions to work with global keyboard shortcuts.")
					.font(.body)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}

			VStack(spacing: 16) {
				PermissionRowView(
					icon: "key.fill",
					title: "Accessibility Access",
					description: "Required for global keyboard shortcuts",
					isGranted: hasPermissions
				)

				if !hasPermissions {
					Button {
						globalShortcutManager.requestAccessibilityPermissions()
						startPermissionChecking()
					} label: {
						Text("Grant Accessibility Access")
					}
				}

				PermissionRowView(
					icon: "mic.fill",
					title: "Microphone Access",
					description: "Required for voice recording",
					isGranted: hasMicrophonePermission
				)
				if !hasMicrophonePermission {
					Button {
						requestMicrophonePermission()
					} label: {
						Text("Grant Microphone Access")
					}
				}
			}

			if hasPermissions && hasMicrophonePermission {
				HStack(spacing: 8) {
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(.green)
					Text("All permissions granted! You're ready to continue.")
						.font(.subheadline)
						.foregroundColor(.green)
				}
				.padding()
				.background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
			} else {
				VStack(spacing: 12) {
					if !hasPermissions {
						Text("After clicking \"Grant Permissions\", you'll see a system dialog.")
							.font(.subheadline)
							.foregroundColor(.secondary)

						Text(
							"Go to System Settings > Privacy & Security > Accessibility and enable Whispera."
						)
						.font(.subheadline)
						.foregroundColor(.secondary)
						.multilineTextAlignment(.center)
					}

					if !hasMicrophonePermission {
						VStack(spacing: 8) {
							Text("Microphone access will be requested when you first try to record.")
								.font(.subheadline)
								.foregroundColor(.secondary)
								.multilineTextAlignment(.center)

							Text(
								"If Whispera doesn't appear in Microphone settings, try recording first to trigger the permission request."
							)
							.font(.caption)
							.foregroundColor(.orange)
							.multilineTextAlignment(.center)
						}
					}
				}
				.padding()
				.background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
			}
		}
		.onAppear {
			checkMicrophonePermission()
			checkAccessibilityPermission()
			startContinuousPermissionChecking()
		}
		.onDisappear {
			stopPermissionChecking()
			stopContinuousPermissionChecking()
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

	private func startPermissionChecking() {
		// Check immediately
		checkAccessibilityPermission()
		checkMicrophonePermission()

		// Then check every 0.5 seconds for changes
		permissionCheckTimer?.invalidate()
		permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
			checkAccessibilityPermission()
			checkMicrophonePermission()

			// Stop checking once both permissions are granted
			if hasPermissions && hasMicrophonePermission {
				stopPermissionChecking()
			}
		}
	}

	private func stopPermissionChecking() {
		permissionCheckTimer?.invalidate()
		permissionCheckTimer = nil
	}

	private func startContinuousPermissionChecking() {
		// Start a timer that continuously checks for permission changes
		accessibilityCheckTimer?.invalidate()
		accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
			checkAccessibilityPermission()
			checkMicrophonePermission()
		}
	}

	private func stopContinuousPermissionChecking() {
		accessibilityCheckTimer?.invalidate()
		accessibilityCheckTimer = nil
	}

	private func requestMicrophonePermission() {
		requestMicrophonePermissionFromUser { granted in
			if granted {
				self.checkMicrophonePermission()
			}
		}
	}

	private func openMicrophoneSettings() {
		if let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
		{
			NSWorkspace.shared.open(url)
		}
	}

	private func requestMicrophonePermissionFromUser(completion: @escaping (Bool) -> Void) {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			print("authorized")
			completion(true)

		case .notDetermined:
			print("notDetermined")
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					completion(granted)
				}
			}

		case .denied, .restricted:
			print("denied")
			openMicrophoneSettings()
			completion(false)

		@unknown default:
			print("unknown")
			completion(false)
		}
	}
}
