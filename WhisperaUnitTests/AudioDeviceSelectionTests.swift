import CoreAudio
import Foundation
import Testing

@testable import Whispera

/// Selection/activation/heal state of AudioDeviceManager against the real
/// CoreAudio device list. Serialized because the persisted selection lives in
/// shared UserDefaults. Tests that would change the machine's default input
/// (activating a specific device) are deliberately absent.
@MainActor
@Suite(.serialized)
struct AudioDeviceSelectionTests {

	private static let persistenceKey = "selectedAudioInputDeviceUID"

	private func withRestoredSelection(_ body: (AudioDeviceManager) async throws -> Void) async rethrows {
		let previous = UserDefaults.standard.string(forKey: Self.persistenceKey)
		defer {
			if let previous {
				UserDefaults.standard.set(previous, forKey: Self.persistenceKey)
			} else {
				UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
			}
		}
		UserDefaults.standard.set(AudioDeviceManager.systemDefaultUID, forKey: Self.persistenceKey)
		try await body(AudioDeviceManager(forTesting: true))
	}

	@Test func selectingAvailableDeviceMirrorsIntoActiveDevice() async {
		await withRestoredSelection { manager in
			guard let device = manager.availableDevices.first else { return }

			manager.selectDevice(uid: device.uid)

			#expect(manager.persistedDeviceUID == device.uid)
			#expect(manager.selectedDevice?.uid == device.uid)
			#expect(manager.activeDevice == device)
			#expect(manager.resolveActiveDeviceID() == device.id)
		}
	}

	@Test func selectingSystemDefaultMirrorsTheDefaultDevice() async {
		await withRestoredSelection { manager in
			manager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)

			#expect(manager.persistedDeviceUID == AudioDeviceManager.systemDefaultUID)
			#expect(manager.selectedDevice == nil)
			#expect(manager.activeDevice == manager.availableDevices.first(where: \.isDefault))
			#expect(manager.resolveActiveDeviceID() == nil)
		}
	}

	@Test func selectingUnresolvableUidHealsToSystemDefault() async {
		await withRestoredSelection { manager in
			guard !manager.availableDevices.isEmpty else { return }

			manager.selectDevice(uid: "stale-uid-that-never-resolves")

			#expect(manager.persistedDeviceUID == AudioDeviceManager.systemDefaultUID)
			#expect(manager.selectedDevice == nil)
			#expect(manager.activeDevice == manager.availableDevices.first(where: \.isDefault))
		}
	}

	@Test func activateHealsSelectionThatWentStaleAfterSelecting() async {
		await withRestoredSelection { manager in
			guard !manager.availableDevices.isEmpty else { return }

			// Writing the key directly simulates a device vanishing between the
			// tap in the picker and the activation at recording start.
			manager.persistedDeviceUID = "stale-uid-that-never-resolves"

			let activated = await manager.activateSelectedDevice()

			#expect(activated, "A healed selection ends up on the system default, which counts as activated")
			#expect(manager.persistedDeviceUID == AudioDeviceManager.systemDefaultUID)
			#expect(manager.selectedDevice == nil)
			#expect(manager.resolveActiveDeviceID() == nil)
		}
	}

	@Test func activatingSystemDefaultSucceedsWithoutTouchingSelection() async {
		await withRestoredSelection { manager in
			manager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)

			let activated = await manager.activateSelectedDevice()

			#expect(activated)
			#expect(manager.persistedDeviceUID == AudioDeviceManager.systemDefaultUID)
		}
	}

	@Test func selectionPostsDeviceChangedNotification() async {
		await withRestoredSelection { manager in
			var received = false
			let observer = NotificationCenter.default.addObserver(
				forName: .audioInputDeviceChanged,
				object: nil,
				queue: nil
			) { _ in
				received = true
			}
			defer { NotificationCenter.default.removeObserver(observer) }

			manager.selectDevice(uid: AudioDeviceManager.systemDefaultUID)

			#expect(received, "selectDevice posts synchronously so mirrors update on the same turn")
		}
	}

	@Test func healingPostsDeviceChangedNotification() async {
		await withRestoredSelection { manager in
			guard !manager.availableDevices.isEmpty else { return }
			manager.persistedDeviceUID = "stale-uid-that-never-resolves"

			var received = false
			let observer = NotificationCenter.default.addObserver(
				forName: .audioInputDeviceChanged,
				object: nil,
				queue: nil
			) { _ in
				received = true
			}
			defer { NotificationCenter.default.removeObserver(observer) }

			await manager.activateSelectedDevice()

			#expect(received, "A healed selection announces itself like an explicit one")
		}
	}
}
