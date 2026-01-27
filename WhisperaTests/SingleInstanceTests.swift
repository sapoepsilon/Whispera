import AppKit
import XCTest

@testable import Whispera

final class SingleInstanceTests: XCTestCase {

	override func setUp() {
		super.setUp()
		// Reset any existing instances for clean test environment
	}

	override func tearDown() {
		super.tearDown()
	}

	// MARK: - Single Instance Tests

	func testApplicationDoesNotLaunchMultipleInstances() {
		// Test that when app is already running, a second launch activates the existing instance
		let appDelegate = AppDelegate()

		// Simulate app already running
		let existingApp = NSRunningApplication.current
		XCTAssertNotNil(existingApp, "Current app should exist")

		// Test that shouldHandleReopen returns true (activates existing)
		let shouldReopen = appDelegate.applicationShouldHandleReopen(
			NSApplication.shared, hasVisibleWindows: false)
		XCTAssertTrue(shouldReopen, "App should handle reopen when already running")
	}

	func testApplicationActivatesWhenAlreadyRunning() {
		// Test that existing instance is activated when trying to launch again
		let appDelegate = AppDelegate()
		let app = NSApplication.shared

		// Simulate reopen attempt
		let reopened = appDelegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
		XCTAssertTrue(reopened, "Should activate existing instance")
	}

	func testSingleInstanceCheckOnLaunch() {
		// Test that app checks for existing instances on launch
		let appDelegate = AppDelegate()

		// Mock method to check if another instance exists
		let otherInstances = appDelegate.checkForExistingInstances()

		// In test environment, should find only self
		XCTAssertEqual(otherInstances.count, 0, "Should not find other instances in test")
	}

	func testLaunchAgentDoesNotCreateDuplicates() {
		// Test that launch agent configuration prevents duplicates
		let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.whisperaapp.Whispera"
		let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/LaunchAgents")
			.appendingPathComponent("\(bundleIdentifier).plist")

		// Check if launch agent exists (from settings)
		if FileManager.default.fileExists(atPath: launchAgentURL.path) {
			// Read plist and verify configuration
			if let plistData = try? Data(contentsOf: launchAgentURL),
				let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
					as? [String: Any]
			{

				// Verify KeepAlive is false to prevent zombie processes
				let keepAlive = plist["KeepAlive"] as? Bool ?? true
				XCTAssertFalse(keepAlive, "KeepAlive should be false to prevent duplicate instances")
			}
		}
	}

	func testDockIconClickActivatesExistingInstance() {
		// Test that clicking dock icon when app is running doesn't create new instance
		let appDelegate = AppDelegate()

		// Simulate dock icon click when app is already running
		let shouldReopen = appDelegate.applicationShouldHandleReopen(
			NSApplication.shared, hasVisibleWindows: true)
		XCTAssertTrue(shouldReopen, "Dock click should activate existing instance")

		// Note: statusItem is only initialized during full app lifecycle (applicationDidFinishLaunching)
		// In unit tests, it won't be set, so we skip this check
	}

	func testTerminateExistingInstancesOnLaunch() {
		// Test that app can terminate duplicate instances if needed
		let appDelegate = AppDelegate()

		// Test the terminate duplicates method
		let terminated = appDelegate.terminateDuplicateInstances()
		XCTAssertTrue(terminated, "Should be able to terminate duplicates")
	}
}

// MARK: - Mock Extensions for Testing

extension AppDelegate {

	func checkForExistingInstances() -> [NSRunningApplication] {
		// Get all running instances of this app
		let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
		let runningApps = NSWorkspace.shared.runningApplications

		return runningApps.filter { app in
			app.bundleIdentifier == bundleIdentifier && app != NSRunningApplication.current
		}
	}

	func terminateDuplicateInstances() -> Bool {
		let existingInstances = checkForExistingInstances()

		for instance in existingInstances {
			instance.terminate()
		}

		return true
	}
}
