import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import Observation

/// What the microphone flow should do for a given authorization status.
enum MicrophonePermissionAction: Equatable {
	case alreadyGranted
	case promptUser
	case openSystemSettings
}

@Observable
class PermissionManager {

	// MARK: - Observable Properties
	var microphonePermissionGranted = false
	var accessibilityPermissionGranted = false
	var needsPermissions = false

	// MARK: - Private Properties
	private var permissionCheckTimer: Timer?

	init() {
		updatePermissionStatus()
		startPeriodicChecks()
	}

	deinit {
		permissionCheckTimer?.invalidate()
	}

	// MARK: - Public Methods

	/// Updates all permission statuses
	func updatePermissionStatus() {
		let newMicrophonePermission = checkMicrophonePermission()
		let newAccessibilityPermission = checkAccessibilityPermission()

		microphonePermissionGranted = newMicrophonePermission
		accessibilityPermissionGranted = newAccessibilityPermission
		needsPermissions = !newMicrophonePermission || !newAccessibilityPermission
	}

	/// Requests microphone permission
	func requestMicrophonePermission() async -> Bool {
		return await withCheckedContinuation { continuation in
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					self.updatePermissionStatus()
					continuation.resume(returning: granted)
				}
			}
		}
	}

	// MARK: - Prompt-first requests (shared by Settings and onboarding, WHI-52)

	/// The one AX consent incantation. Shows the OS dialog the first time; on
	/// later calls (after a denial) it is silent, so callers pair it with the
	/// Accessibility pane.
	static func promptForAccessibilityAccess() -> Bool {
		let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
		return AXIsProcessTrustedWithOptions(options)
	}

	/// Prompt-first accessibility request: triggers the OS dialog when it can
	/// and opens the Accessibility pane when access is still missing.
	@discardableResult
	func requestAccessibilityAccess() -> Bool {
		let granted = Self.promptForAccessibilityAccess()
		if !granted {
			openAccessibilitySettings()
		}
		updatePermissionStatus()
		return granted
	}

	/// Pure decision for the microphone flow — kept separate so it's testable.
	static func microphoneAction(for status: AVAuthorizationStatus) -> MicrophonePermissionAction {
		switch status {
		case .authorized: return .alreadyGranted
		case .notDetermined: return .promptUser
		case .denied, .restricted: return .openSystemSettings
		@unknown default: return .openSystemSettings
		}
	}

	/// Prompt-first microphone request: real OS prompt when undetermined,
	/// Microphone pane when previously denied.
	@discardableResult
	func requestMicrophoneAccess() async -> Bool {
		switch Self.microphoneAction(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
		case .alreadyGranted:
			return true
		case .promptUser:
			return await requestMicrophonePermission()
		case .openSystemSettings:
			openMicrophoneSettings()
			return false
		}
	}

	/// Opens System Settings to the Privacy & Security section
	func openSystemSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
			NSWorkspace.shared.open(url)
		}
	}

	/// Opens Accessibility settings specifically
	func openAccessibilitySettings() {
		if let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
		{
			NSWorkspace.shared.open(url)
		}
	}

	/// Opens Microphone settings specifically
	func openMicrophoneSettings() {
		if let url = URL(
			string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
		{
			NSWorkspace.shared.open(url)
		}
	}

	// MARK: - Private Methods

	private func checkMicrophonePermission() -> Bool {
		return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
	}

	private func checkAccessibilityPermission() -> Bool {
		return AXIsProcessTrusted()
	}

	private func startPeriodicChecks() {
		// Check permissions every 2 seconds to detect changes
		permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
			[weak self] _ in
			self?.updatePermissionStatus()
		}
	}
}

// MARK: - Permission Status Helpers

extension PermissionManager {

	/// Returns a user-friendly description of missing permissions
	var missingPermissionsDescription: String {
		var missing: [String] = []

		if !microphonePermissionGranted {
			missing.append("Microphone access")
		}

		if !accessibilityPermissionGranted {
			missing.append("Accessibility access")
		}

		if missing.isEmpty {
			return "All permissions granted"
		} else if missing.count == 1 {
			return "\(missing[0]) required"
		} else {
			return "\(missing.joined(separator: " and ")) required"
		}
	}

	/// Returns the permission status as a color
	var permissionStatusColor: NSColor {
		return needsPermissions ? .systemOrange : .systemGreen
	}

	/// Returns an appropriate system icon for permission status
	var permissionStatusIcon: String {
		return needsPermissions ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
	}
}
