import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Core Audio access to output devices, behind a protocol so the mute/restore
/// bookkeeping can be tested without touching the real speakers.
protocol OutputDeviceAudioControl {
	func defaultOutputDevice() -> AudioDeviceID?
	func deviceID(forUID uid: String) -> AudioDeviceID?
	func uid(for device: AudioDeviceID) -> String?
	func isMuteSettable(_ device: AudioDeviceID) -> Bool
	func isMuted(_ device: AudioDeviceID) -> Bool?
	@discardableResult func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool
	func volume(of device: AudioDeviceID) -> Float?
	@discardableResult func setVolume(_ volume: Float, on device: AudioDeviceID) -> Bool
}

struct CoreAudioOutputControl: OutputDeviceAudioControl {
	private static let mainElement = kAudioObjectPropertyElementMain

	private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(
			mSelector: selector,
			mScope: kAudioDevicePropertyScopeOutput,
			mElement: Self.mainElement
		)
	}

	func defaultOutputDevice() -> AudioDeviceID? {
		var deviceID: AudioDeviceID = 0
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: Self.mainElement
		)
		let status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
		return status == noErr && deviceID != 0 ? deviceID : nil
	}

	func deviceID(forUID uid: String) -> AudioDeviceID? {
		var deviceID: AudioDeviceID = 0
		var cfUID = uid as CFString
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: Self.mainElement
		)
		let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
			AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject), &address,
				UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID)
		}
		return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
	}

	func uid(for device: AudioDeviceID) -> String? {
		var uid: CFString = "" as CFString
		var size = UInt32(MemoryLayout<CFString>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceUID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: Self.mainElement
		)
		let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
		return status == noErr ? uid as String : nil
	}

	func isMuteSettable(_ device: AudioDeviceID) -> Bool {
		var address = address(kAudioDevicePropertyMute)
		guard AudioObjectHasProperty(device, &address) else { return false }
		var settable: DarwinBoolean = false
		let status = AudioObjectIsPropertySettable(device, &address, &settable)
		return status == noErr && settable.boolValue
	}

	func isMuted(_ device: AudioDeviceID) -> Bool? {
		var address = address(kAudioDevicePropertyMute)
		var value: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
		return status == noErr ? value != 0 : nil
	}

	func setMuted(_ muted: Bool, on device: AudioDeviceID) -> Bool {
		var address = address(kAudioDevicePropertyMute)
		var value: UInt32 = muted ? 1 : 0
		let status = AudioObjectSetPropertyData(
			device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
		return status == noErr
	}

	func volume(of device: AudioDeviceID) -> Float? {
		var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
		var value: Float32 = 0
		var size = UInt32(MemoryLayout<Float32>.size)
		let status = AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &value)
		return status == noErr ? value : nil
	}

	func setVolume(_ volume: Float, on device: AudioDeviceID) -> Bool {
		var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
		var settable: DarwinBoolean = false
		guard AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr,
			settable.boolValue
		else { return false }
		var value = Float32(volume)
		let status = AudioHardwareServiceSetPropertyData(
			device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
		return status == noErr
	}
}

/// Silences the default output device while recording so music or video audio
/// does not bleed into the microphone, then puts it back exactly as it was.
@MainActor
final class SystemOutputMuter {
	static let shared = SystemOutputMuter()
	static let settingKey = "muteOutputWhileRecording"
	static let pendingRestoreKey = "outputMutePendingRestore"

	enum SavedState: Equatable {
		case mute(device: AudioDeviceID)
		case volume(device: AudioDeviceID, previous: Float)
	}

	private let control: OutputDeviceAudioControl
	private let defaults: UserDefaults
	private(set) var savedState: SavedState?
	private var terminationObserver: NSObjectProtocol?

	init(control: OutputDeviceAudioControl = CoreAudioOutputControl(), defaults: UserDefaults = .standard) {
		self.control = control
		self.defaults = defaults
	}

	var isEnabled: Bool { defaults.bool(forKey: Self.settingKey) }

	func muteIfEnabled() {
		guard isEnabled else { return }
		mute()
	}

	func mute() {
		guard savedState == nil, let device = control.defaultOutputDevice() else { return }

		if control.isMuteSettable(device) {
			guard control.isMuted(device) != true else { return }
			guard control.setMuted(true, on: device) else { return }
			savedState = .mute(device: device)
		} else if let previous = control.volume(of: device), previous > 0 {
			guard control.setVolume(0, on: device) else { return }
			savedState = .volume(device: device, previous: previous)
		} else {
			return
		}

		persistPendingRestore(device: device)
		observeTermination()
		AppLogger.shared.audioManager.info("Muted system output while recording")
	}

	func restore() {
		guard let state = savedState else { return }
		switch state {
		case .mute(let device):
			control.setMuted(false, on: device)
		case .volume(let device, let previous):
			control.setVolume(previous, on: device)
		}
		savedState = nil
		defaults.removeObject(forKey: Self.pendingRestoreKey)
		AppLogger.shared.audioManager.info("Restored system output after recording")
	}

	/// Undoes a mute left behind when the app quit or crashed mid-recording.
	func recoverFromUncleanExit() {
		guard let pending = defaults.dictionary(forKey: Self.pendingRestoreKey) else { return }
		defaults.removeObject(forKey: Self.pendingRestoreKey)
		guard let uid = pending["uid"] as? String, let device = control.deviceID(forUID: uid) else {
			return
		}
		if let previous = (pending["volume"] as? NSNumber)?.floatValue {
			control.setVolume(previous, on: device)
		} else {
			control.setMuted(false, on: device)
		}
		AppLogger.shared.audioManager.info("Restored system output left muted by a previous session")
	}

	private func persistPendingRestore(device: AudioDeviceID) {
		guard let uid = control.uid(for: device) else { return }
		var pending: [String: Any] = ["uid": uid]
		if case .volume(_, let previous) = savedState {
			pending["volume"] = previous
		}
		defaults.set(pending, forKey: Self.pendingRestoreKey)
	}

	private func observeTermination() {
		guard terminationObserver == nil else { return }
		terminationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.restore()
			}
		}
	}
}
