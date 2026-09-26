import Foundation
import Testing

@testable import Whispera

@MainActor
struct MicrophoneFallbackTests {
	@Test func fallbackOverridesEverySavedChoice() {
		for persisted in ["usb-mic", "built-in", AudioDeviceManager.systemDefaultUID] {
			#expect(
				InputDeviceResolver.effectiveUID(
					persistedUID: persisted, clamshellUID: "clamshell-mic", isLidClosed: true,
					fallbackToSystemDefault: true, availableUIDs: ["usb-mic", "built-in", "clamshell-mic"])
					== AudioDeviceManager.systemDefaultUID)
		}
	}

	@Test func fallbackLastsOnlyForTheRecordingSession() {
		let manager = AudioDeviceManager(forTesting: true)
		let savedChoice = manager.persistedDeviceUID

		manager.beginFallbackToSystemDefault()
		#expect(manager.isUsingFallbackInput)
		#expect(manager.effectiveDeviceUID == AudioDeviceManager.systemDefaultUID)
		#expect(manager.resolveActiveDeviceID() == nil)
		#expect(manager.persistedDeviceUID == savedChoice, "Fallback must not overwrite the saved device")

		manager.endRecordingSession()
		#expect(!manager.isUsingFallbackInput)
		#expect(manager.activeSessionDevice == nil)
	}
}
