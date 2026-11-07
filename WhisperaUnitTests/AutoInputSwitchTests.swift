import CoreAudio
import Foundation
import Testing

@testable import Whispera

private final class FakeInputDeviceProvider: AudioInputDeviceProviding, @unchecked Sendable {
	private let lock = NSLock()
	private var current: [AudioInputDevice]

	init(devices: [AudioInputDevice]) { current = devices }

	var devices: [AudioInputDevice] {
		get { lock.withLock { current } }
		set { lock.withLock { current = newValue } }
	}

	func inputDevices() -> [AudioInputDevice] { devices }
}

private func device(
	_ id: AudioDeviceID, _ uid: String, _ name: String, isDefault: Bool = false,
	transport: UInt32 = kAudioDeviceTransportTypeUSB, alive: Bool = true, running: Bool = false
) -> AudioInputDevice {
	AudioInputDevice(
		id: id, uid: uid, name: name, isDefault: isDefault, transportType: transport, isAlive: alive,
		isRunningSomewhere: running)
}

private let builtIn = device(1, "built-in", "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
private let builtInDefault = device(
	1, "built-in", "MacBook Pro Microphone", isDefault: true, transport: kAudioDeviceTransportTypeBuiltIn)
private let usb = device(2, "usb-mic", "USB Mic")
private let blackHole = device(3, "blackhole", "BlackHole 2ch", transport: kAudioDeviceTransportTypeVirtual)
private let airPods = device(4, "airpods", "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)

struct InputFailoverPlannerTests {
	private func fallback(_ plan: InputFailoverPlanner.Plan) -> InputFallback? {
		if case .fallback(let fallback) = plan { return fallback }
		return nil
	}

	@Test func availablePreferredDeviceIsUsed() {
		let plan = InputFailoverPlanner.plan(
			preferredUID: "airpods", devices: [builtInDefault, airPods], lastWorkingUID: nil)
		#expect(plan == .usePreferred)
	}

	@Test func missingPreferredFallsBackToSystemDefaultAndNamesIt() throws {
		let plan = InputFailoverPlanner.plan(
			preferredUID: "airpods", devices: [builtInDefault, usb], lastWorkingUID: "usb-mic",
			knownNames: ["airpods": "AirPods Pro"])
		let chosen = try #require(fallback(plan))
		#expect(chosen.uid == "built-in")
		#expect(chosen.reason == .missing)
		#expect(chosen.notice.contains("MacBook Pro Microphone"))
		#expect(chosen.notice.contains("AirPods Pro"))
	}

	@Test func listedButDeadPreferredIsNotResponding() throws {
		let deadAirPods = device(4, "airpods", "AirPods Pro", alive: false)
		let chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: "airpods", devices: [builtInDefault, deadAirPods], lastWorkingUID: nil)))
		#expect(chosen.uid == "built-in")
		#expect(chosen.reason == .notResponding)
		#expect(chosen.unavailableName == "AirPods Pro")
	}

	@Test func lastWorkingInputComesAfterTheSystemDefault() throws {
		let deadDefault = device(
			1, "built-in", "MacBook Pro Microphone", isDefault: true, transport: kAudioDeviceTransportTypeBuiltIn,
			alive: false)
		let chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: "airpods", devices: [deadDefault, airPods.withAlive(false), usb, blackHole],
					lastWorkingUID: "blackhole")))
		#expect(chosen.uid == "blackhole", "The last input that worked is trusted, even a virtual one")
	}

	@Test func anyInputPrefersBuiltInThenRunningHardwareAndSkipsVirtual() throws {
		let otherUSB = device(5, "usb-2", "Interface", running: true)
		// Silent default, no last-working device: built-in comes first among the rest
		var chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: AudioDeviceManager.systemDefaultUID,
					devices: [blackHole, usb, otherUSB, builtIn, device(6, "def", "Dock Mic", isDefault: true)],
					unusableUIDs: ["def"], lastWorkingUID: nil)))
		#expect(chosen.uid == "built-in")
		#expect(chosen.reason == .silent)

		chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: "airpods", devices: [blackHole, usb, otherUSB], lastWorkingUID: nil)))
		#expect(chosen.uid == "usb-2", "Hardware already running somewhere is proven to work")

		let onlyVirtual = InputFailoverPlanner.plan(
			preferredUID: "airpods", devices: [blackHole], lastWorkingUID: nil)
		#expect(onlyVirtual == .noWorkingInput)
	}

	@Test func silentInputsAreSkipped() throws {
		let chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: "usb-mic", devices: [builtInDefault, usb, airPods],
					unusableUIDs: ["usb-mic", "built-in"], lastWorkingUID: nil, reasonOverride: .silent)))
		#expect(chosen.uid == "airpods")
		#expect(chosen.notice.contains("isn't picking up any sound"))
	}

	@Test func nothingUsableMeansNoWorkingInput() {
		#expect(
			InputFailoverPlanner.plan(
				preferredUID: "airpods", devices: [builtIn.withAlive(false)], lastWorkingUID: nil)
				== .noWorkingInput)
		#expect(
			InputFailoverPlanner.plan(
				preferredUID: AudioDeviceManager.systemDefaultUID, devices: [], lastWorkingUID: nil)
				== .noWorkingInput)
	}

	@Test func unknownMissingDeviceGetsAGenericNotice() throws {
		let chosen = try #require(
			fallback(
				InputFailoverPlanner.plan(
					preferredUID: "gone", devices: [builtInDefault], lastWorkingUID: nil)))
		#expect(chosen.unavailableName == nil)
		#expect(chosen.notice.contains("MacBook Pro Microphone"))
	}
}

struct InputSignalProbeTests {
	private let start = Date(timeIntervalSince1970: 1000)

	@Test func noiseFloorCountsAsSignal() {
		var probe = InputSignalProbe()
		probe.ingest(samples: [0, 0, 0.00003, 0], at: start)
		#expect(probe.evaluate(now: start.addingTimeInterval(5)) == .heard)
	}

	@Test func digitalSilenceForTheWholeWindowIsSilent() {
		var probe = InputSignalProbe()
		probe.ingest(samples: [Float](repeating: 0, count: 1024), at: start)
		#expect(!probe.isArmed, "Audio alone never starts the window; the caller arms it")
		probe.arm(at: start)
		#expect(probe.evaluate(now: start.addingTimeInterval(1)) == .listening)
		probe.ingest(samples: [Float](repeating: 0, count: 1024), at: start.addingTimeInterval(1.5))
		#expect(probe.evaluate(now: start.addingTimeInterval(InputSignalProbe.window)) == .silent)
	}

	@Test func noAudioArrivingAtAllIsSilent() {
		var probe = InputSignalProbe()
		#expect(probe.evaluate(now: start.addingTimeInterval(60)) == .listening, "Not judged before it is armed")
		probe.arm(at: start)
		#expect(probe.evaluate(now: start.addingTimeInterval(InputSignalProbe.window)) == .silent)
	}

	@Test func exemptAndResetBehave() {
		var probe = InputSignalProbe()
		probe.exempt()
		probe.arm(at: start)
		#expect(probe.evaluate(now: start.addingTimeInterval(10)) == .exempt)
		probe.reset()
		#expect(probe.verdict == .listening)
		#expect(!probe.isArmed)
	}

	@Test func recorderMeteringFloorIsSilence() {
		var probe = InputSignalProbe()
		// AVAudioRecorder reports -160 dB for a dead input
		probe.arm(at: start)
		probe.ingest(peak: pow(10, -160 / 20), at: start)
		#expect(probe.evaluate(now: start.addingTimeInterval(InputSignalProbe.window)) == .silent)
	}
}

struct SilentInputRegistryTests {
	@Test func silentInputsExpireAndCanBeForgiven() {
		let now = Date(timeIntervalSince1970: 0)
		var registry = SilentInputRegistry()
		registry.markSilent("usb-mic", now: now)
		registry.markSilent("airpods", now: now)
		#expect(registry.silentUIDs(now: now.addingTimeInterval(60)) == ["usb-mic", "airpods"])
		registry.forgive("airpods")
		#expect(registry.silentUIDs(now: now.addingTimeInterval(60)) == ["usb-mic"])
		#expect(registry.silentUIDs(now: now.addingTimeInterval(SilentInputRegistry.quarantine + 1)).isEmpty)
	}
}

@MainActor
struct AutoInputSwitchManagerTests {
	private func makeManager(
		_ devices: [AudioInputDevice], preferred: String, autoSwitch: Bool? = nil, suite: String = #function
	) -> (AudioDeviceManager, UserDefaults, FakeInputDeviceProvider) {
		let name = "AutoInputSwitchTests.\(suite).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		defaults.set(preferred, forKey: AudioDeviceManager.persistedDeviceKey)
		if let autoSwitch { defaults.set(autoSwitch, forKey: AutoInputSwitchSettings.enabledKey) }
		let provider = FakeInputDeviceProvider(devices: devices)
		let manager = AudioDeviceManager(forTesting: true, provider: provider, defaults: defaults)
		// The real lid state of the Mac running the tests must not decide them
		manager.isLidClosed = { false }
		manager.currentDefaultInputID = { devices.first(where: \.isDefault)?.id }
		return (manager, defaults, provider)
	}

	@Test func settingDefaultsToOn() {
		let (manager, _, _) = makeManager([builtInDefault], preferred: "airpods")
		#expect(manager.isAutoSwitchEnabled)
	}

	@Test func missingDeviceSwitchesForTheSessionOnly() throws {
		let (manager, defaults, _) = makeManager([builtInDefault, usb], preferred: "airpods")
		defaults.set("AirPods Pro", forKey: AutoInputSwitchSettings.selectedDeviceNameKey)

		let fallback = try #require(manager.planSessionInput())
		#expect(fallback.name == "MacBook Pro Microphone")
		#expect(fallback.notice.contains("AirPods Pro"))
		#expect(manager.isUsingFallbackInput)
		#expect(manager.sessionFallback == fallback)
		// The fallback is the system default, so the recording follows the default and a kept-open
		// stream on it stays reusable
		#expect(manager.effectiveDeviceUID == AudioDeviceManager.systemDefaultUID)
		#expect(manager.currentInputDevice?.uid == "built-in")
		#expect(manager.persistedDeviceUID == "airpods", "The saved choice comes back next time")

		manager.endRecordingSession()
		#expect(!manager.isUsingFallbackInput)
		#expect(manager.sessionFallback == nil)
		#expect(manager.effectiveDeviceUID == "airpods")
	}

	@Test func nonDefaultFallbackIsRecordedFrom() throws {
		let deadDefault = device(
			1, "built-in", "MacBook Pro Microphone", isDefault: true, transport: kAudioDeviceTransportTypeBuiltIn,
			alive: false)
		let (manager, _, _) = makeManager([deadDefault, usb], preferred: "airpods")
		let fallback = try #require(manager.planSessionInput())
		#expect(fallback.uid == "usb-mic")
		#expect(manager.effectiveDeviceUID == "usb-mic")
		#expect(manager.resolveActiveDeviceID() == usb.id)
		#expect(manager.expectedInputDeviceID() == usb.id)
	}

	@Test func availablePreferredDeviceNeedsNoFallback() {
		let (manager, _, _) = makeManager([builtInDefault, airPods], preferred: "airpods")
		#expect(manager.planSessionInput() == nil)
		#expect(!manager.isUsingFallbackInput)
		#expect(manager.effectiveDeviceUID == "airpods")
	}

	@Test func turningTheSettingOffKeepsTheOldBehavior() {
		let (manager, _, _) = makeManager([builtInDefault, usb], preferred: "airpods", autoSwitch: false)
		#expect(manager.planSessionInput() == nil)
		#expect(manager.effectiveDeviceUID == "airpods")
		#expect(manager.resolveActiveDeviceID() == nil, "Missing devices still record from the system default")

		#expect(manager.beginFallback(afterLosing: airPods) == nil)
		#expect(manager.effectiveDeviceUID == AudioDeviceManager.systemDefaultUID)
	}

	@Test func silentInputMovesToTheNextOneAndIsSkippedNextTime() throws {
		let (manager, _, _) = makeManager([builtInDefault, usb, airPods], preferred: "usb-mic")
		#expect(manager.planSessionInput() == nil)

		let fallback = try #require(manager.markInputSilent(usb))
		#expect(fallback.uid == "built-in")
		#expect(fallback.reason == .silent)
		#expect(fallback.notice.contains("USB Mic"))
		#expect(manager.currentInputDevice?.uid == "built-in")

		// The built-in mic turns out silent too: on to the next one, still naming the USB mic
		let next = try #require(manager.markInputSilent(builtInDefault))
		#expect(next.uid == "airpods")
		#expect(next.unavailableName == "USB Mic")

		// Nothing left to try
		#expect(manager.markInputSilent(airPods) == nil)
	}

	@Test func silentInputIsSkippedByTheNextRecordingUntilItReconnects() async throws {
		let (manager, _, provider) = makeManager([builtInDefault, usb], preferred: "usb-mic")
		_ = manager.markInputSilent(usb)
		manager.endRecordingSession()

		// Skipped up front, so the next recording does not lose its first seconds to it
		let skipped = try #require(manager.planSessionInput())
		#expect(skipped.uid == "built-in")
		#expect(skipped.reason == .silent)
		manager.endRecordingSession()

		provider.devices = [builtInDefault]
		await manager.refreshDevices()
		provider.devices = [builtInDefault, usb]
		await manager.refreshDevices()
		#expect(manager.planSessionInput() == nil, "A reconnected microphone gets another chance")
	}

	@Test func lostDeviceMidRecordingUsesThePlanner() throws {
		let (manager, _, _) = makeManager([builtIn, usb], preferred: "airpods")
		let fallback = try #require(manager.beginFallback(afterLosing: airPods))
		#expect(fallback.reason == .disconnected)
		#expect(fallback.notice.contains("AirPods Pro"))
		#expect(fallback.uid == "built-in")
		#expect(manager.effectiveDeviceUID == "built-in")
	}

	@Test func closedLidSkipsTheBuiltInMicrophone() throws {
		let (manager, _, _) = makeManager([builtInDefault, usb], preferred: "airpods")
		manager.isLidClosed = { true }
		let fallback = try #require(manager.planSessionInput())
		#expect(fallback.uid == "usb-mic", "The built-in mic is cut off while the lid is closed")
		manager.endRecordingSession()

		manager.isLidClosed = { false }
		#expect(manager.planSessionInput()?.uid == "built-in")
	}

	@Test func closedLidWithOnlyTheBuiltInMicLeavesNothingToSwitchTo() {
		let (manager, _, _) = makeManager([builtInDefault], preferred: AudioDeviceManager.systemDefaultUID)
		manager.isLidClosed = { true }
		#expect(manager.planSessionInput() == nil)
		#expect(!manager.isUsingFallbackInput)
	}

	/// Losing the device restores the default saved before the recording, which the cached list
	/// does not show yet; the fallback must follow the restored default, not the stale flag.
	@Test func lostDeviceFollowsTheRestoredDefaultNotTheCachedOne() throws {
		let otherMic = device(7, "other-mic", "Desk Mic", transport: kAudioDeviceTransportTypeVirtual)
		let (manager, _, _) = makeManager([builtInDefault, otherMic], preferred: "airpods")
		manager.isLidClosed = { true }
		manager.currentDefaultInputID = { otherMic.id }
		let fallback = try #require(manager.beginFallback(afterLosing: airPods))
		#expect(fallback.uid == "other-mic")
		#expect(fallback.notice.contains("Desk Mic"))
		#expect(manager.effectiveDeviceUID == AudioDeviceManager.systemDefaultUID)
	}

	@Test func workingInputIsRememberedAsLastKnownGood() {
		let (manager, defaults, _) = makeManager([builtInDefault, usb], preferred: "usb-mic")
		manager.markInputWorking(usb)
		#expect(manager.lastWorkingDeviceUID == "usb-mic")
		#expect(defaults.string(forKey: AutoInputSwitchSettings.lastWorkingDeviceKey) == "usb-mic")
	}
}

extension AudioInputDevice {
	fileprivate func withAlive(_ alive: Bool) -> AudioInputDevice {
		var copy = self
		copy.isAlive = alive
		return copy
	}
}
