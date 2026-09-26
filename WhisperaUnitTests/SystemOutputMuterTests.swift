import CoreAudio
import Foundation
import Testing

@testable import Whispera

private final class FakeOutputControl: OutputDeviceAudioControl {
	var defaultDevice: AudioDeviceID? = 42
	var muteSettable = true
	var muted: [AudioDeviceID: Bool] = [:]
	var volumes: [AudioDeviceID: Float] = [:]
	var volumeSettable = true
	var uids: [AudioDeviceID: String] = [42: "speakers-uid"]

	func defaultOutputDevice() -> AudioDeviceID? { defaultDevice }
	func deviceID(forUID uid: String) -> AudioDeviceID? { uids.first { $0.value == uid }?.key }
	func uid(for device: AudioDeviceID) -> String? { uids[device] }
	func isMuteSettable(_ device: AudioDeviceID) -> Bool { muteSettable }
	func isMuted(_ device: AudioDeviceID) -> Bool? { muteSettable ? (muted[device] ?? false) : nil }
	func setMuted(_ value: Bool, on device: AudioDeviceID) -> Bool {
		muted[device] = value
		return true
	}
	func volume(of device: AudioDeviceID) -> Float? { volumes[device] }
	func setVolume(_ value: Float, on device: AudioDeviceID) -> Bool {
		guard volumeSettable else { return false }
		volumes[device] = value
		return true
	}
}

@MainActor
struct SystemOutputMuterTests {
	private func makeDefaults(_ name: String) throws -> (UserDefaults, String) {
		let suite = "SystemOutputMuterTests.\(name).\(UUID().uuidString)"
		return (try #require(UserDefaults(suiteName: suite)), suite)
	}

	@Test func disabledByDefault() throws {
		let (defaults, suite) = try makeDefaults("disabled")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.muteIfEnabled()

		#expect(control.muted[42] == nil)
		#expect(muter.savedState == nil)
	}

	@Test func mutesAndRestoresWhenEnabled() throws {
		let (defaults, suite) = try makeDefaults("mute")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(true, forKey: SystemOutputMuter.settingKey)
		let control = FakeOutputControl()
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.muteIfEnabled()
		#expect(control.muted[42] == true)
		#expect(muter.savedState == .mute(device: 42))
		#expect(defaults.dictionary(forKey: SystemOutputMuter.pendingRestoreKey) != nil)

		muter.restore()
		#expect(control.muted[42] == false)
		#expect(muter.savedState == nil)
		#expect(defaults.dictionary(forKey: SystemOutputMuter.pendingRestoreKey) == nil)
	}

	@Test func leavesAlreadyMutedOutputAlone() throws {
		let (defaults, suite) = try makeDefaults("already")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		control.muted[42] = true
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.mute()
		muter.restore()

		#expect(control.muted[42] == true, "Restoring must not unmute output the user had muted")
	}

	@Test func fallsBackToVolumeWhenDeviceHasNoMute() throws {
		let (defaults, suite) = try makeDefaults("volume")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		control.muteSettable = false
		control.volumes[42] = 0.6
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.mute()
		#expect(control.volumes[42] == 0)
		#expect(muter.savedState == .volume(device: 42, previous: 0.6))

		muter.restore()
		#expect(control.volumes[42] == 0.6)
	}

	@Test func doesNothingWhenVolumeCannotBeSet() throws {
		let (defaults, suite) = try makeDefaults("unsettable")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		control.muteSettable = false
		control.volumeSettable = false
		control.volumes[42] = 0.6
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.mute()
		#expect(muter.savedState == nil)
		#expect(defaults.dictionary(forKey: SystemOutputMuter.pendingRestoreKey) == nil)
	}

	@Test func secondMuteKeepsOriginalState() throws {
		let (defaults, suite) = try makeDefaults("twice")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		control.muteSettable = false
		control.volumes[42] = 0.8
		let muter = SystemOutputMuter(control: control, defaults: defaults)

		muter.mute()
		muter.mute()
		muter.restore()

		#expect(control.volumes[42] == 0.8)
	}

	@Test func recoversMuteLeftByCrashedSession() throws {
		let (defaults, suite) = try makeDefaults("recover")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		let crashed = SystemOutputMuter(control: control, defaults: defaults)
		crashed.mute()
		#expect(control.muted[42] == true)

		SystemOutputMuter(control: control, defaults: defaults).recoverFromUncleanExit()

		#expect(control.muted[42] == false)
		#expect(defaults.dictionary(forKey: SystemOutputMuter.pendingRestoreKey) == nil)
	}

	@Test func recoversVolumeLeftByCrashedSession() throws {
		let (defaults, suite) = try makeDefaults("recoverVolume")
		defer { defaults.removePersistentDomain(forName: suite) }
		let control = FakeOutputControl()
		control.muteSettable = false
		control.volumes[42] = 0.3
		SystemOutputMuter(control: control, defaults: defaults).mute()

		SystemOutputMuter(control: control, defaults: defaults).recoverFromUncleanExit()

		#expect(control.volumes[42] == 0.3)
	}

	@Test func realDefaultOutputDeviceIsReadable() {
		let control = CoreAudioOutputControl()
		guard let device = control.defaultOutputDevice() else { return }
		let uid = control.uid(for: device)
		#expect(uid != nil)
		if let uid {
			#expect(control.deviceID(forUID: uid) == device)
		}
	}
}
