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

	/// AVAudioRecorder cannot move to another device, so a file recording ends with what it has
	/// instead of silently recording nothing on the vanished microphone.
	@Test func fileRecordingFinishesWhileStreamAndLiveFollowTheFallback() {
		#expect(InputLossResponse.decide(path: .file, isStartingCapture: false) == .finishRecording)
		#expect(InputLossResponse.decide(path: .stream, isStartingCapture: false) == .followFallbackInput)
		#expect(InputLossResponse.decide(path: .live, isStartingCapture: false) == .followFallbackInput)
		for path in [CapturePath.file, .stream, nil] {
			#expect(InputLossResponse.decide(path: path, isStartingCapture: true) == .restartStartup)
		}
	}

	@Test func noticesNameTheLostDevice() {
		#expect(InputLossResponse.fallbackNotice(lostDevice: "USB Mic").contains("USB Mic"))
		#expect(InputLossResponse.finishedNotice(lostDevice: "USB Mic").contains("USB Mic"))
	}

	@Test func fallbackNoticeNotifiesWhenNoPillCanShowIt() {
		#expect(InputLossResponse.fallbackNoticeNeedsNotification(isLive: true, overlay: .pill))
		#expect(InputLossResponse.fallbackNoticeNeedsNotification(isLive: false, overlay: .minimal))
		#expect(InputLossResponse.fallbackNoticeNeedsNotification(isLive: false, overlay: .none))
		#expect(!InputLossResponse.fallbackNoticeNeedsNotification(isLive: false, overlay: .pill))
	}

	@Test func deviceLossWithoutARecordingChangesNothing() {
		let manager = AudioManager()
		manager.handleInputDeviceLost(name: "USB Mic")
		#expect(manager.inputNotice == nil)
		#expect(manager.transcriptionError == nil)
	}
}
