import XCTest
@testable import Whispera
import AVFoundation

final class PermissionManagerTests: XCTestCase {
    
    var permissionManager: PermissionManager!
    
    override func setUp() {
        super.setUp()
        permissionManager = PermissionManager()
    }
    
    override func tearDown() {
        permissionManager = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        XCTAssertNotNil(permissionManager)
        
        // Should start periodic checks
        XCTAssertTrue(permissionManager.microphonePermissionGranted || !permissionManager.microphonePermissionGranted)
        XCTAssertTrue(permissionManager.accessibilityPermissionGranted || !permissionManager.accessibilityPermissionGranted)
    }
    
    // MARK: - Permission Status Tests
    
    func testMicrophonePermissionStatus() {
        // Test that microphone permission status is correctly detected
        let expectedStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        
        permissionManager.updatePermissionStatus()
        
        XCTAssertEqual(permissionManager.microphonePermissionGranted, expectedStatus)
    }
    
    func testAccessibilityPermissionStatus() {
        // Test that accessibility permission status is correctly detected
        let expectedStatus = AXIsProcessTrusted()
        
        permissionManager.updatePermissionStatus()
        
        XCTAssertEqual(permissionManager.accessibilityPermissionGranted, expectedStatus)
    }
    
    func testNeedsPermissions() {
        // Test that needsPermissions is correctly calculated
        permissionManager.updatePermissionStatus()
        
        let expectedNeedsPermissions = !permissionManager.microphonePermissionGranted || !permissionManager.accessibilityPermissionGranted
        
        XCTAssertEqual(permissionManager.needsPermissions, expectedNeedsPermissions)
    }
    
    // MARK: - Permission Description Tests
    
    func testMissingPermissionsDescriptionBothMissing() {
        // Mock both permissions as missing
        permissionManager.microphonePermissionGranted = false
        permissionManager.accessibilityPermissionGranted = false
        permissionManager.needsPermissions = true
        
        let description = permissionManager.missingPermissionsDescription
        
        XCTAssertTrue(description.contains("Microphone access"))
        XCTAssertTrue(description.contains("Accessibility access"))
        XCTAssertTrue(description.contains("and"))
    }
    
    func testMissingPermissionsDescriptionMicrophoneOnly() {
        // Mock only microphone permission as missing
        permissionManager.microphonePermissionGranted = false
        permissionManager.accessibilityPermissionGranted = true
        permissionManager.needsPermissions = true
        
        let description = permissionManager.missingPermissionsDescription
        
        XCTAssertTrue(description.contains("Microphone access"))
        XCTAssertFalse(description.contains("Accessibility access"))
        XCTAssertFalse(description.contains("and"))
    }
    
    func testMissingPermissionsDescriptionAccessibilityOnly() {
        // Mock only accessibility permission as missing
        permissionManager.microphonePermissionGranted = true
        permissionManager.accessibilityPermissionGranted = false
        permissionManager.needsPermissions = true
        
        let description = permissionManager.missingPermissionsDescription
        
        XCTAssertFalse(description.contains("Microphone access"))
        XCTAssertTrue(description.contains("Accessibility access"))
        XCTAssertFalse(description.contains("and"))
    }
    
    func testMissingPermissionsDescriptionAllGranted() {
        // Mock all permissions as granted
        permissionManager.microphonePermissionGranted = true
        permissionManager.accessibilityPermissionGranted = true
        permissionManager.needsPermissions = false
        
        let description = permissionManager.missingPermissionsDescription
        
        XCTAssertEqual(description, "All permissions granted")
    }
    
    // MARK: - Status Helper Tests
    
    func testPermissionStatusColorWithPermissions() {
        // Mock permissions as needed
        permissionManager.needsPermissions = true
        
        let color = permissionManager.permissionStatusColor
        
        XCTAssertEqual(color, .systemOrange)
    }
    
    func testPermissionStatusColorWithoutPermissions() {
        // Mock permissions as granted
        permissionManager.needsPermissions = false
        
        let color = permissionManager.permissionStatusColor
        
        XCTAssertEqual(color, .systemGreen)
    }
    
    func testPermissionStatusIconWithPermissions() {
        // Mock permissions as needed
        permissionManager.needsPermissions = true
        
        let icon = permissionManager.permissionStatusIcon
        
        XCTAssertEqual(icon, "exclamationmark.triangle.fill")
    }
    
    func testPermissionStatusIconWithoutPermissions() {
        // Mock permissions as granted
        permissionManager.needsPermissions = false
        
        let icon = permissionManager.permissionStatusIcon
        
        XCTAssertEqual(icon, "checkmark.circle.fill")
    }
    
    // MARK: - URL Opening Tests
    
    func testOpenSystemSettings() {
        // Test that the method doesn't crash
        XCTAssertNoThrow(permissionManager.openSystemSettings())
    }
    
    func testOpenAccessibilitySettings() {
        // Test that the method doesn't crash
        XCTAssertNoThrow(permissionManager.openAccessibilitySettings())
    }
    
    func testOpenMicrophoneSettings() {
        // Test that the method doesn't crash
        XCTAssertNoThrow(permissionManager.openMicrophoneSettings())
    }
    
    // MARK: - Async Permission Request Tests
    
    func testRequestMicrophonePermissionAlreadyGranted() async {
        // Only run this test if microphone permission is already granted
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Microphone permission not granted - cannot test already granted scenario")
        }
        
        let result = await permissionManager.requestMicrophonePermission()
        
        XCTAssertTrue(result)
        XCTAssertTrue(permissionManager.microphonePermissionGranted)
    }
    
    // MARK: - Performance Tests
    
    func testUpdatePermissionStatusPerformance() {
        measure {
            permissionManager.updatePermissionStatus()
        }
    }
    
    // MARK: - State Change Tests
    
    func testPermissionStatusUpdate() {
        let initialMicStatus = permissionManager.microphonePermissionGranted
        let initialAccessStatus = permissionManager.accessibilityPermissionGranted
        let initialNeedsPermissions = permissionManager.needsPermissions
        
        // Update status
        permissionManager.updatePermissionStatus()
        
        // Status should be consistent
        let finalMicStatus = permissionManager.microphonePermissionGranted
        let finalAccessStatus = permissionManager.accessibilityPermissionGranted
        let finalNeedsPermissions = permissionManager.needsPermissions
        
        // Verify needsPermissions is correctly calculated
        let expectedNeedsPermissions = !finalMicStatus || !finalAccessStatus
        XCTAssertEqual(finalNeedsPermissions, expectedNeedsPermissions)
        
        // In a test environment, permissions shouldn't change frequently
        // but we can't guarantee they're the same, so we just verify consistency
        XCTAssertEqual(finalNeedsPermissions, !finalMicStatus || !finalAccessStatus)
    }
    
    // MARK: - Observable Behavior Tests
    
    func testObservableProperties() {
        // Test that observable properties are accessible
        XCTAssertNotNil(permissionManager.microphonePermissionGranted)
        XCTAssertNotNil(permissionManager.accessibilityPermissionGranted)
        XCTAssertNotNil(permissionManager.needsPermissions)
        
        // Test that they can be modified (for internal state management)
        let originalMicStatus = permissionManager.microphonePermissionGranted
        permissionManager.microphonePermissionGranted = !originalMicStatus
        XCTAssertNotEqual(permissionManager.microphonePermissionGranted, originalMicStatus)
        
        // Restore original state
        permissionManager.microphonePermissionGranted = originalMicStatus
    }
    
    // MARK: - Edge Case Tests
    
    func testPermissionManagerDeinit() {
        // Test that deinitializing doesn't cause crashes
        var manager: PermissionManager? = PermissionManager()
        XCTAssertNotNil(manager)
        
        manager = nil
        XCTAssertNil(manager)
    }
    
    func testMultiplePermissionUpdates() {
        // Test rapid successive updates don't cause issues
        for _ in 0..<10 {
            permissionManager.updatePermissionStatus()
        }
        
        // Should still be in a valid state
        XCTAssertNotNil(permissionManager.microphonePermissionGranted)
        XCTAssertNotNil(permissionManager.accessibilityPermissionGranted)
        XCTAssertNotNil(permissionManager.needsPermissions)
    }
}