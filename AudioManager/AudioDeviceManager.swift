import AudioToolbox
import CoreAudio
import Foundation
import SwiftUI

enum AudioDeviceIcon: String, Sendable {
	case builtIn = "laptopcomputer"
	case airpodsPro = "airpodspro"
	case airpodsMax = "airpodsmax"
	case airpods = "airpods.gen3"
	case headphones = "headphones"
	case iPhone = "iphone"
	case usb = "music.mic"
	case virtual = "waveform"
	case generic = "mic.fill"

	static func resolve(transportType: UInt32, deviceName: String) -> AudioDeviceIcon {
		let lowered = deviceName.lowercased()

		if lowered.contains("iphone") || lowered.contains("ipad") { return .iPhone }

		switch transportType {
		case kAudioDeviceTransportTypeBuiltIn:
			return .builtIn
		case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
			if lowered.contains("airpods pro") { return .airpodsPro }
			if lowered.contains("airpods max") { return .airpodsMax }
			if lowered.contains("airpods") { return .airpods }
			return .headphones
		case kAudioDeviceTransportTypeUSB:
			return .usb
		case kAudioDeviceTransportTypeVirtual:
			return .virtual
		default:
			return .generic
		}
	}
}

struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
	let id: AudioDeviceID
	let uid: String
	let name: String
	let isDefault: Bool
	let transportType: UInt32

	var icon: AudioDeviceIcon {
		AudioDeviceIcon.resolve(transportType: transportType, deviceName: name)
	}

	var iconName: String {
		icon.rawValue
	}

	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.uid == rhs.uid
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(uid)
	}
}

extension Notification.Name {
	static let audioDevicesChanged = Notification.Name("AudioDevicesChanged")
	static let audioInputDeviceChanged = Notification.Name("AudioInputDeviceChanged")
	static let devicePickerToggled = Notification.Name("DevicePickerToggled")
	static let devicePickerDismissed = Notification.Name("DevicePickerDismissed")
}

@MainActor
@Observable
final class AudioDeviceManager {
	static let shared = AudioDeviceManager()
	static let systemDefaultUID = "system-default"

	private(set) var availableDevices: [AudioInputDevice] = []
	private(set) var selectedDevice: AudioInputDevice?

	@ObservationIgnored
	@AppStorage("selectedAudioInputDeviceUID") var persistedDeviceUID = AudioDeviceManager.systemDefaultUID

	@ObservationIgnored
	private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
	@ObservationIgnored
	private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
	@ObservationIgnored
	private var savedSystemDefaultDeviceID: AudioDeviceID?

	private init() {
		refreshDevices()
		installDeviceChangeListeners()
		applyPersistedSelection()
	}

	// For testing
	init(forTesting: Bool) {
		refreshDevices()
		applyPersistedSelection()
	}

	// MARK: - Public API

	func refreshDevices() {
		let defaultID = getSystemDefaultInputDeviceID()
		availableDevices = enumerateInputDevices(defaultDeviceID: defaultID)
		applyPersistedSelection()
		AppLogger.shared.deviceManager.debug("Refreshed devices: \(availableDevices.map(\.name))")
	}

	func selectDevice(uid: String) {
		persistedDeviceUID = uid
		applyPersistedSelection()
		NotificationCenter.default.post(name: .audioInputDeviceChanged, object: nil)
		AppLogger.shared.deviceManager.info("Selected device: \(uid)")
	}

	func activateSelectedDevice() async {
		guard persistedDeviceUID != AudioDeviceManager.systemDefaultUID else {
			AppLogger.shared.deviceManager.debug("activateSelectedDevice: system default selected, skipping")
			restoreSystemDefault()
			return
		}

		guard let device = availableDevices.first(where: { $0.uid == persistedDeviceUID }) else {
			AppLogger.shared.deviceManager.error("activateSelectedDevice: device \(persistedDeviceUID) not found in \(availableDevices.map { "\($0.name):\($0.uid)" })")
			restoreSystemDefault()
			return
		}

		let currentDefault = getSystemDefaultInputDeviceID()
		let currentDefaultName = currentDefault.flatMap { getDeviceName(for: $0) } ?? "unknown"
		AppLogger.shared.deviceManager.info("activateSelectedDevice: current default=\(currentDefaultName) (ID: \(currentDefault ?? 0)), switching to \(device.name) (ID: \(device.id))")

		if savedSystemDefaultDeviceID == nil {
			savedSystemDefaultDeviceID = currentDefault
		}

		let targetDeviceID = device.id
		let targetDeviceName = device.name
		await Task.detached(priority: .userInitiated) {
			Self.setSystemDefaultInputDeviceSync(targetDeviceID)
		}.value

		let newDefault = getSystemDefaultInputDeviceID()
		let newDefaultName = newDefault.flatMap { getDeviceName(for: $0) } ?? "unknown"
		if newDefault == targetDeviceID {
			AppLogger.shared.deviceManager.info("activateSelectedDevice: verified system default changed to \(newDefaultName)")
		} else {
			AppLogger.shared.deviceManager.error("activateSelectedDevice: FAILED - system default is still \(newDefaultName) (ID: \(newDefault ?? 0)), expected \(targetDeviceName) (ID: \(targetDeviceID))")
		}
	}

	func restoreSystemDefault() {
		guard let original = savedSystemDefaultDeviceID else { return }
		setSystemDefaultInputDevice(original)
		let name = getDeviceName(for: original) ?? "unknown"
		AppLogger.shared.deviceManager.info("Restored original system default: \(name) (ID: \(original))")
		savedSystemDefaultDeviceID = nil
	}

	private nonisolated static func setSystemDefaultInputDeviceSync(_ deviceID: AudioDeviceID) {
		var mutableDeviceID = deviceID
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectSetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			UInt32(MemoryLayout<AudioDeviceID>.size),
			&mutableDeviceID
		)

		if status != noErr {
			AppLogger.shared.deviceManager.error("setSystemDefaultInputDevice: FAILED with OSStatus \(status) for ID \(deviceID)")
		}
	}

	private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
		Self.setSystemDefaultInputDeviceSync(deviceID)
	}

	func resolveActiveDeviceID() -> AudioDeviceID? {
		if persistedDeviceUID == AudioDeviceManager.systemDefaultUID {
			AppLogger.shared.deviceManager.debug("resolveActiveDeviceID → nil (system default)")
			return nil
		}

		guard let device = availableDevices.first(where: { $0.uid == persistedDeviceUID }) else {
			AppLogger.shared.deviceManager.info(
				"Persisted device \(persistedDeviceUID) not available, falling back to system default")
			return nil
		}

		AppLogger.shared.deviceManager.info("resolveActiveDeviceID → \(device.name) (ID: \(device.id), UID: \(device.uid))")
		return device.id
	}

	// MARK: - Private

	private func applyPersistedSelection() {
		if persistedDeviceUID == AudioDeviceManager.systemDefaultUID {
			selectedDevice = nil
		} else {
			selectedDevice = availableDevices.first(where: { $0.uid == persistedDeviceUID })
		}
	}

	private func enumerateInputDevices(defaultDeviceID: AudioDeviceID?) -> [AudioInputDevice] {
		var propertySize: UInt32 = 0
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		var status = AudioObjectGetPropertyDataSize(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			&propertySize
		)

		guard status == noErr, propertySize > 0 else { return [] }

		let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
		var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

		status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			&propertySize,
			&deviceIDs
		)

		guard status == noErr else { return [] }

		var devices: [AudioInputDevice] = []

		for deviceID in deviceIDs {
			guard isInputDevice(deviceID),
				let uid = getDeviceUID(for: deviceID),
				let name = getDeviceName(for: deviceID)
			else { continue }

			devices.append(
				AudioInputDevice(
					id: deviceID,
					uid: uid,
					name: name,
					isDefault: deviceID == defaultDeviceID,
					transportType: getDeviceTransportType(for: deviceID)
				))
		}

		return devices
	}

	private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
		var propertySize: UInt32 = 0
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreams,
			mScope: kAudioObjectPropertyScopeInput,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyDataSize(
			deviceID,
			&address,
			0,
			nil,
			&propertySize
		)

		return status == noErr && propertySize > 0
	}

	private func getDeviceUID(for deviceID: AudioDeviceID) -> String? {
		var uid: CFString = "" as CFString
		var size = UInt32(MemoryLayout<CFString>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceUID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(
			deviceID,
			&address,
			0,
			nil,
			&size,
			&uid
		)

		return status == noErr ? uid as String : nil
	}

	private func getDeviceName(for deviceID: AudioDeviceID) -> String? {
		var name: CFString = "" as CFString
		var size = UInt32(MemoryLayout<CFString>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceNameCFString,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(
			deviceID,
			&address,
			0,
			nil,
			&size,
			&name
		)

		return status == noErr ? name as String : nil
	}

	private func getDeviceTransportType(for deviceID: AudioDeviceID) -> UInt32 {
		var transportType: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyTransportType,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(
			deviceID,
			&address,
			0,
			nil,
			&size,
			&transportType
		)

		return status == noErr ? transportType : 0
	}

	private func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
		var deviceID: AudioDeviceID = 0
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let status = AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&address,
			0,
			nil,
			&size,
			&deviceID
		)

		return status == noErr && deviceID != 0 ? deviceID : nil
	}

	// MARK: - Device Change Listeners

	private func installDeviceChangeListeners() {
		var devicesAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
			Task { @MainActor in
				self?.refreshDevices()
				NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
			}
		}
		deviceListListenerBlock = devicesBlock

		AudioObjectAddPropertyListenerBlock(
			AudioObjectID(kAudioObjectSystemObject),
			&devicesAddress,
			DispatchQueue.main,
			devicesBlock
		)

		var defaultAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)

		let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
			Task { @MainActor in
				self?.refreshDevices()
			}
		}
		defaultDeviceListenerBlock = defaultBlock

		AudioObjectAddPropertyListenerBlock(
			AudioObjectID(kAudioObjectSystemObject),
			&defaultAddress,
			DispatchQueue.main,
			defaultBlock
		)
	}

	private func removeDeviceChangeListeners() {
		if let block = deviceListListenerBlock {
			var address = AudioObjectPropertyAddress(
				mSelector: kAudioHardwarePropertyDevices,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain
			)
			AudioObjectRemovePropertyListenerBlock(
				AudioObjectID(kAudioObjectSystemObject),
				&address,
				DispatchQueue.main,
				block
			)
		}

		if let block = defaultDeviceListenerBlock {
			var address = AudioObjectPropertyAddress(
				mSelector: kAudioHardwarePropertyDefaultInputDevice,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain
			)
			AudioObjectRemovePropertyListenerBlock(
				AudioObjectID(kAudioObjectSystemObject),
				&address,
				DispatchQueue.main,
				block
			)
		}
	}

	deinit {
		// Singleton - listeners cleaned up when process exits
	}
}
