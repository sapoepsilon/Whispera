import CoreAudio
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

struct InternalInputDeviceTests {
	@Test func avAudioEngineDefaultAggregateIsHidden() {
		// QA: the input menu listed Whispera's own "CADefaultDeviceAggregate-39621-0" while recording
		#expect(
			AudioInputDevice.isInternal(
				uid: "CADefaultDeviceAggregate-39621-0", name: "CADefaultDeviceAggregate-39621-0",
				transportType: kAudioDeviceTransportTypeAggregate, isPrivateAggregate: true))
		#expect(
			AudioInputDevice.isInternal(
				uid: "CADefaultDeviceAggregate-39621-1", name: "CADefaultDeviceAggregate-39621-1",
				transportType: kAudioDeviceTransportTypeAutoAggregate, isPrivateAggregate: false))
		#expect(
			AudioInputDevice.isInternal(
				uid: "VPAUAggregateAudioDevice-0x600000", name: "VPAUAggregateAudioDevice-0x600000",
				transportType: kAudioDeviceTransportTypeAggregate, isPrivateAggregate: false))
	}

	@Test func privateAggregatesAreHidden() {
		#expect(
			AudioInputDevice.isInternal(
				uid: "com.example.recorder.aggregate", name: "Recorder Mix",
				transportType: kAudioDeviceTransportTypeAggregate, isPrivateAggregate: true))
	}

	@Test func devicesPeopleChoseStayListed() {
		// An aggregate built in Audio MIDI Setup is public
		#expect(
			!AudioInputDevice.isInternal(
				uid: "~:AMS2_Aggregate:0", name: "Aggregate Device",
				transportType: kAudioDeviceTransportTypeAggregate, isPrivateAggregate: false))
		#expect(
			!AudioInputDevice.isInternal(
				uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transportType: kAudioDeviceTransportTypeVirtual,
				isPrivateAggregate: false))
		#expect(
			!AudioInputDevice.isInternal(
				uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
				transportType: kAudioDeviceTransportTypeBuiltIn, isPrivateAggregate: false))
		// The private flag alone never hides a device that is not an aggregate
		#expect(
			!AudioInputDevice.isInternal(
				uid: "AppleUSBAudioEngine:GeneralPlus:USB Audio Device:131000:2", name: "USB Audio Device",
				transportType: kAudioDeviceTransportTypeUSB, isPrivateAggregate: true))
	}
}
