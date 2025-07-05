import Foundation
import AVFoundation
import ApplicationServices
import AppKit
import Observation

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
    
    /// Opens System Settings to the Privacy & Security section
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Opens Accessibility settings specifically
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Opens Microphone settings specifically  
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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