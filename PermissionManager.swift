import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import Observation

@Observable
class PermissionManager {

	// MARK: - Observable Properties
	var microphonePermissionGranted = false
	var accessibilityPermissionGranted = false
	var needsPermissions = false

	// MARK: - Private Properties
	@ObservationIgnored private var permissionCheckTimer: Timer?
	@ObservationIgnored private var activationObserver: NSObjectProtocol?
	@ObservationIgnored private let microphoneCheck: () -> Bool
	@ObservationIgnored private let accessibilityCheck: () -> Bool

	init(
		microphoneCheck: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
		accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
		monitorsChanges: Bool = true
	) {
		self.microphoneCheck = microphoneCheck
		self.accessibilityCheck = accessibilityCheck
		updatePermissionStatus()
		guard monitorsChanges else { return }
		activationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.updatePermissionStatus()
		}
		schedulePolling()
	}

	deinit {
		permissionCheckTimer?.invalidate()
		if let activationObserver {
			NotificationCenter.default.removeObserver(activationObserver)
		}
	}

	// MARK: - Public Methods

	/// Updates all permission statuses. Only changed values are written, so the views observing
	/// these properties are not invalidated on every check.
	func updatePermissionStatus() {
		let newMicrophonePermission = microphoneCheck()
		let newAccessibilityPermission = accessibilityCheck()
		let newNeedsPermissions = !newMicrophonePermission || !newAccessibilityPermission

		if microphonePermissionGranted != newMicrophonePermission {
			microphonePermissionGranted = newMicrophonePermission
		}
		if accessibilityPermissionGranted != newAccessibilityPermission {
			accessibilityPermissionGranted = newAccessibilityPermission
		}
		if needsPermissions != newNeedsPermissions {
			needsPermissions = newNeedsPermissions
		}
		schedulePolling()
	}

	/// How often permissions are re-checked. Fast while something is missing so a grant in System
	/// Settings shows up promptly; slow once everything is granted, where only a revocation is left
	/// to notice and app activation re-checks anyway.
	static func pollInterval(needsPermissions: Bool) -> TimeInterval {
		needsPermissions ? 2 : 30
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

	private func schedulePolling() {
		guard activationObserver != nil else { return }
		let interval = Self.pollInterval(needsPermissions: needsPermissions)
		if let timer = permissionCheckTimer, timer.isValid, timer.timeInterval == interval { return }
		permissionCheckTimer?.invalidate()
		let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
			self?.updatePermissionStatus()
		}
		timer.tolerance = interval / 4
		RunLoop.main.add(timer, forMode: .common)
		permissionCheckTimer = timer
	}
}

// MARK: - Permission Status Helpers

extension PermissionManager {

	/// Returns a user-friendly description of missing permissions
	var missingPermissionsDescription: String {
		switch (microphonePermissionGranted, accessibilityPermissionGranted) {
		case (true, true):
			return String(localized: "All permissions granted")
		case (false, true):
			return String(localized: "Microphone access required")
		case (true, false):
			return String(localized: "Accessibility access required")
		case (false, false):
			return String(localized: "Microphone access and Accessibility access required")
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
