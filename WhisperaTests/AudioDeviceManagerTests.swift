import CoreAudio
import XCTest

@testable import Whispera

@MainActor
final class AudioDeviceManagerTests: XCTestCase {

	var deviceManager: AudioDeviceManager!

	override func setUp() async throws {
		deviceManager = AudioDeviceManager.shared
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
	}

	override func tearDown() async throws {
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		deviceManager = nil
	}

	// MARK: - Device Enumeration

	func testEnumerateDevicesReturnsAtLeastOneDevice() async throws {
		deviceManager.refreshDevices()
		XCTAssertFalse(
			deviceManager.availableDevices.isEmpty,
			"Should find at least one input device")
	}

	func testAllDevicesHaveUIDsAndNames() async throws {
		deviceManager.refreshDevices()
		for device in deviceManager.availableDevices {
			XCTAssertFalse(device.uid.isEmpty, "Device '\(device.name)' should have a UID")
			XCTAssertFalse(device.name.isEmpty, "Device with UID '\(device.uid)' should have a name")
		}
	}

	func testExactlyOneDefaultDevice() async throws {
		deviceManager.refreshDevices()
		let defaultDevices = deviceManager.availableDevices.filter { $0.isDefault }
		XCTAssertEqual(defaultDevices.count, 1, "There should be exactly one default input device")
	}

	func testDeviceUIDsAreUnique() async throws {
		deviceManager.refreshDevices()
		let uids = deviceManager.availableDevices.map(\.uid)
		let uniqueUIDs = Set(uids)
		XCTAssertEqual(uids.count, uniqueUIDs.count, "All device UIDs should be unique")
	}

	// MARK: - Device Selection

	func testSelectSystemDefault() async throws {
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		XCTAssertEqual(deviceManager.persistedDeviceUID, AudioDeviceManager.systemDefaultUID)
		XCTAssertNil(deviceManager.selectedDevice, "selectedDevice should be nil for system default")
	}

	func testSelectSpecificDevice() async throws {
		deviceManager.refreshDevices()
		guard let firstDevice = deviceManager.availableDevices.first else {
			throw XCTSkip("No input devices available")
		}

		deviceManager.selectDevice(uid: firstDevice.uid)
		XCTAssertEqual(deviceManager.persistedDeviceUID, firstDevice.uid)
		XCTAssertEqual(deviceManager.selectedDevice?.uid, firstDevice.uid)
	}

	// MARK: - Persistence

	func testPersistsToUserDefaults() async throws {
		deviceManager.refreshDevices()
		guard let firstDevice = deviceManager.availableDevices.first else {
			throw XCTSkip("No input devices available")
		}

		deviceManager.selectDevice(uid: firstDevice.uid)

		let stored = UserDefaults.standard.string(forKey: "selectedAudioInputDeviceUID")
		XCTAssertEqual(stored, firstDevice.uid, "Device UID should be persisted to UserDefaults")

		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
	}

	func testSystemDefaultPersistence() async throws {
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		let stored = UserDefaults.standard.string(forKey: "selectedAudioInputDeviceUID")
		XCTAssertEqual(stored, AudioDeviceManager.systemDefaultUID)
	}

	// MARK: - Fallback

	func testFallbackWhenDeviceUnavailable() async throws {
		deviceManager.selectDevice(uid: "non-existent-device-uid")
		let resolvedID = deviceManager.resolveActiveDeviceID()
		XCTAssertNil(
			resolvedID,
			"Should return nil (system default) when selected device is unavailable")
	}

	func testResolveSystemDefault() async throws {
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		let resolvedID = deviceManager.resolveActiveDeviceID()
		XCTAssertNil(resolvedID, "Should return nil for system default")
	}

	func testResolveSpecificDevice() async throws {
		deviceManager.refreshDevices()
		guard let firstDevice = deviceManager.availableDevices.first else {
			throw XCTSkip("No input devices available")
		}

		deviceManager.selectDevice(uid: firstDevice.uid)
		let resolvedID = deviceManager.resolveActiveDeviceID()
		XCTAssertNotNil(resolvedID, "Should return a valid device ID for an available device")
		XCTAssertEqual(resolvedID, firstDevice.id)
	}

	// MARK: - Edge Case

	func testSystemDefaultUnavailable() async throws {
		// Documents the edge case where the system default might not be available.
		// resolveActiveDeviceID returns nil for system default, which means
		// AVAudioEngine picks the default itself. If that also fails,
		// engine.start() will throw — handled by AudioManager's error path.
		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)
		let resolvedID = deviceManager.resolveActiveDeviceID()
		XCTAssertNil(resolvedID)
	}

	// MARK: - Notifications

	func testDeviceSelectionPostsNotification() async throws {
		let expectation = XCTestExpectation(description: "Device change notification")

		let observer = NotificationCenter.default.addObserver(
			forName: .audioInputDeviceChanged,
			object: nil,
			queue: .main
		) { _ in
			expectation.fulfill()
		}

		deviceManager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)

		await fulfillment(of: [expectation], timeout: 2.0)
		NotificationCenter.default.removeObserver(observer)
	}

	// MARK: - Model Tests

	func testAudioInputDeviceEquality() async throws {
		let device1 = AudioInputDevice(id: 1, uid: "uid-1", name: "Mic 1", isDefault: true)
		let device2 = AudioInputDevice(id: 2, uid: "uid-1", name: "Mic 1 Renamed", isDefault: false)
		let device3 = AudioInputDevice(id: 3, uid: "uid-2", name: "Mic 2", isDefault: false)

		XCTAssertEqual(device1, device2, "Devices with same UID should be equal")
		XCTAssertNotEqual(device1, device3, "Devices with different UIDs should not be equal")
	}

	func testAudioInputDeviceHashable() async throws {
		let device1 = AudioInputDevice(id: 1, uid: "uid-1", name: "Mic 1", isDefault: true)
		let device2 = AudioInputDevice(id: 2, uid: "uid-1", name: "Mic 1", isDefault: false)

		var set = Set<AudioInputDevice>()
		set.insert(device1)
		set.insert(device2)

		XCTAssertEqual(set.count, 1, "Devices with same UID should hash to same bucket")
	}
}
