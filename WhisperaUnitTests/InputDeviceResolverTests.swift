import Foundation
import Testing

@testable import Whispera

struct InputDeviceResolverTests {
	private let available: Set<String> = ["usb-mic", "built-in", "clamshell-mic"]

	@Test func lidOpenUsesSavedDevice() {
		#expect(
			InputDeviceResolver.effectiveUID(
				persistedUID: "built-in", clamshellUID: "clamshell-mic", isLidClosed: false,
				availableUIDs: available) == "built-in")
	}

	@Test func lidClosedUsesClamshellDevice() {
		#expect(
			InputDeviceResolver.effectiveUID(
				persistedUID: "built-in", clamshellUID: "clamshell-mic", isLidClosed: true,
				availableUIDs: available) == "clamshell-mic")
	}

	@Test func lidClosedWithoutClamshellDeviceKeepsSavedDevice() {
		#expect(
			InputDeviceResolver.effectiveUID(
				persistedUID: AudioDeviceManager.systemDefaultUID, clamshellUID: "", isLidClosed: true,
				availableUIDs: available) == AudioDeviceManager.systemDefaultUID)
	}

	@Test func lidClosedWithUnpluggedClamshellDeviceKeepsSavedDevice() {
		#expect(
			InputDeviceResolver.effectiveUID(
				persistedUID: "usb-mic", clamshellUID: "gone-mic", isLidClosed: true,
				availableUIDs: available) == "usb-mic")
	}

	@Test func clamshellDetectorAnswersWithoutCrashing() {
		let closed = ClamshellDetector.isLidClosed()
		if !ClamshellDetector.hasLid {
			#expect(!closed, "A Mac without a lid can never report a closed lid")
		}
	}
}
