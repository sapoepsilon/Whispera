import CoreAudio
import Foundation
import Testing

@testable import Whispera

/// Stands in for the CoreAudio seams: which device is the default output, which
/// output devices exist, whether their mute is settable, what they currently read
/// as, and every write we make. A device absent from the mute table reads as
/// unreadable, which is how the "could not read the mute state" case is set up.
///
/// File-scoped and lock-guarded so it stays nonisolated — the muter's `@Sendable`
/// closures call it off the main actor.
private final class FakeAudioDevices: @unchecked Sendable {
	private let lock = NSLock()
	private var _defaultDevice: AudioDeviceID?
	private var _settable: Bool
	private var _muted: [AudioDeviceID: Bool]
	private let _writesTakeEffect: Bool
	private var _writes: [(device: AudioDeviceID, muted: Bool)] = []

	init(
		defaultDevice: AudioDeviceID? = 1,
		settable: Bool = true,
		muted: Bool? = false,
		others: [AudioDeviceID: Bool] = [:],
		writesTakeEffect: Bool = true
	) {
		_defaultDevice = defaultDevice
		_settable = settable
		_muted = others
		if let defaultDevice, let muted { _muted[defaultDevice] = muted }
		_writesTakeEffect = writesTakeEffect
	}

	var defaultDevice: AudioDeviceID? {
		get { lock.withLock { _defaultDevice } }
		set { lock.withLock { _defaultDevice = newValue } }
	}

	var writes: [(device: AudioDeviceID, muted: Bool)] { lock.withLock { _writes } }
	var outputs: [AudioDeviceID] { lock.withLock { _muted.keys.sorted() } }

	func read(_ device: AudioDeviceID) -> Bool? { lock.withLock { _muted[device] } }
	func settable(_ device: AudioDeviceID) -> Bool { lock.withLock { _settable } }

	func write(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
		lock.withLock {
			_writes.append((device, muted))
			// A write that reports success without changing anything is exactly the
			// CoreAudio failure this class exists to reproduce.
			if _writesTakeEffect { _muted[device] = muted }
			return true
		}
	}
}

@MainActor
struct SystemAudioMuterTests {

	/// `observesTermination: false` keeps each instance out of the host app's
	/// notification centre; the watchdog is off unless a test asks for it.
	private func makeMuter(
		devices: FakeAudioDevices,
		enabled: Bool = true,
		maxMuteSeconds: Double = 0
	) -> SystemAudioMuter {
		SystemAudioMuter(
			isEnabled: { enabled },
			defaultOutputDevice: { devices.defaultDevice },
			outputDevices: { devices.outputs },
			muteIsSettable: { devices.settable($0) },
			readMute: { devices.read($0) },
			writeMute: { devices.write($0, $1) },
			maxMuteSeconds: maxMuteSeconds,
			observesTermination: false
		)
	}

	// MARK: - Mute

	@Test func mutesAnUnmutedDeviceOnce() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()

		#expect(devices.writes.count == 1)
		#expect(devices.writes.first?.device == 42)
		#expect(devices.writes.first?.muted == true)
		#expect(muter.mutedDevice == 42)
	}

	@Test func secondMuteIsANoOp() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		muter.muteForDictation()

		#expect(devices.writes.count == 1)
	}

	/// The user muted their own output. Recording that as ours would mean unmuting
	/// them when the dictation ends.
	@Test func deviceAlreadyMutedByTheUserIsLeftAlone() {
		let devices = FakeAudioDevices(defaultDevice: 42, muted: true)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		#expect(devices.writes.isEmpty)
		#expect(muter.mutedDevice == nil)

		muter.restoreAfterDictation()
		#expect(devices.writes.isEmpty)
	}

	@Test func deviceWithoutASettableMuteIsLeftAlone() {
		let devices = FakeAudioDevices(defaultDevice: 42, settable: false)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()

		#expect(devices.writes.isEmpty)
		#expect(muter.mutedDevice == nil)
	}

	@Test func unreadableMuteStateIsLeftAlone() {
		let devices = FakeAudioDevices(defaultDevice: 42, muted: nil)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()

		#expect(devices.writes.isEmpty)
		#expect(muter.mutedDevice == nil)
	}

	@Test func missingDefaultDeviceIsLeftAlone() {
		let devices = FakeAudioDevices(defaultDevice: nil)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()

		#expect(devices.writes.isEmpty)
		#expect(muter.mutedDevice == nil)
	}

	@Test func disabledSettingNeverTouchesTheDevice() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices, enabled: false)

		muter.muteForDictation()
		muter.restoreAfterDictation()

		#expect(devices.writes.isEmpty)
		#expect(muter.mutedDevice == nil)
	}

	// MARK: - Restore

	@Test func restoreUnmutesTheDeviceWeMuted() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		muter.restoreAfterDictation()

		#expect(devices.writes.count == 2)
		#expect(devices.writes.last?.device == 42)
		#expect(devices.writes.last?.muted == false)
		#expect(muter.mutedDevice == nil)
	}

	@Test func restoreWithoutAMuteIsANoOp() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.restoreAfterDictation()

		#expect(devices.writes.isEmpty)
	}

	@Test func secondRestoreIsANoOp() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		muter.restoreAfterDictation()
		muter.restoreAfterDictation()

		#expect(devices.writes.count == 2)
	}

	/// AirPods disconnecting mid-dictation moves the default output. Unmuting "the
	/// current default" would leave the muted device muted and touch a device we
	/// never muted.
	@Test func restoreTargetsTheOriginalDeviceAfterTheDefaultChanges() {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		devices.defaultDevice = 99
		muter.restoreAfterDictation()

		#expect(devices.writes.last?.device == 42)
		#expect(devices.writes.last?.muted == false)
	}

	/// The measured bug: AirPods Max (114) muted, then they sleep and the default
	/// moves to the built-in speakers (71). Restore must still clear 114.
	@Test func restoreUnmutesTheMutedDeviceEvenWhenItIsNoLongerTheDefault() {
		let devices = FakeAudioDevices(defaultDevice: 114, others: [71: false])
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		devices.defaultDevice = 71
		muter.restoreAfterDictation()

		#expect(devices.read(114) == false)
		#expect(devices.writes.count == 2)
		#expect(devices.writes.last?.device == 114)
		#expect(devices.writes.last?.muted == false)
	}

	@Test func restoreUnmutesEveryMutedOutputDevice() {
		let devices = FakeAudioDevices(defaultDevice: 42, others: [71: true, 88: true])
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		muter.restoreAfterDictation()

		#expect(devices.read(42) == false)
		#expect(devices.read(71) == false)
		#expect(devices.read(88) == false)
		#expect(devices.writes.filter { !$0.muted }.count == 3)
	}

	@Test func restoreLeavesAlreadyUnmutedDevicesAlone() {
		let devices = FakeAudioDevices(defaultDevice: 42, others: [71: false, 88: false])
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()
		muter.restoreAfterDictation()

		#expect(devices.writes.count == 2)
		#expect(devices.writes.allSatisfy { $0.device == 42 })
	}

	// MARK: - Write verification

	/// CoreAudio returned noErr for the restore write that never landed, so an
	/// unverified write must not be recorded as a mute we can put back.
	@Test func writeThatDoesNotTakeEffectIsNotTreatedAsSuccess() {
		let devices = FakeAudioDevices(defaultDevice: 42, writesTakeEffect: false)
		let muter = makeMuter(devices: devices)

		muter.muteForDictation()

		#expect(devices.writes.count == 1)
		#expect(muter.mutedDevice == nil)
	}

	// MARK: - Watchdog

	@Test func watchdogRestoresAfterMaxMuteSeconds() async {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices, maxMuteSeconds: 0.02)

		muter.muteForDictation()
		await muter.flush()

		#expect(devices.writes.count == 2)
		#expect(devices.writes.last?.muted == false)
		#expect(muter.mutedDevice == nil)
	}

	@Test func watchdogDoesNotFireAfterAnOrdinaryRestore() async {
		let devices = FakeAudioDevices(defaultDevice: 42)
		let muter = makeMuter(devices: devices, maxMuteSeconds: 0.02)

		muter.muteForDictation()
		muter.restoreAfterDictation()
		try? await Task.sleep(nanoseconds: 60_000_000)

		#expect(devices.writes.count == 2)
	}
}
