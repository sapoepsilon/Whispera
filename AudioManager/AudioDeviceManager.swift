import AudioToolbox
import CoreAudio
import Foundation
import IOKit
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
	static let activeInputDeviceLost = Notification.Name("ActiveInputDeviceLost")
}

@MainActor
@Observable
final class AudioDeviceManager {
	static let shared = AudioDeviceManager()
	nonisolated static let systemDefaultUID = "system-default"

	private(set) var availableDevices: [AudioInputDevice] = []
	private(set) var selectedDevice: AudioInputDevice?
	/// True while a recording runs on the system default because its device vanished.
	private(set) var isUsingFallbackInput = false
	@ObservationIgnored
	private(set) var activeSessionDevice: AudioInputDevice?

	@ObservationIgnored
	@AppStorage("selectedAudioInputDeviceUID") var persistedDeviceUID = AudioDeviceManager.systemDefaultUID
	@ObservationIgnored
	@AppStorage(AudioDeviceManager.clamshellDeviceKey) var clamshellDeviceUID = ""

	nonisolated static let clamshellDeviceKey = "clamshellAudioInputDeviceUID"

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

	/// The device a recording should use right now: the saved choice, or the
	/// clamshell microphone when the lid is closed and one is configured.
	var effectiveDeviceUID: String {
		InputDeviceResolver.effectiveUID(
			persistedUID: persistedDeviceUID,
			clamshellUID: clamshellDeviceUID,
			isLidClosed: !clamshellDeviceUID.isEmpty && ClamshellDetector.isLidClosed(),
			fallbackToSystemDefault: isUsingFallbackInput,
			availableUIDs: Set(availableDevices.map(\.uid))
		)
	}

	/// Moves the current recording to the system default input without touching
	/// the saved device choice, which comes back for the next recording.
	func beginFallbackToSystemDefault() {
		isUsingFallbackInput = true
		activeSessionDevice = nil
		restoreSystemDefault()
	}

	func endRecordingSession() {
		isUsingFallbackInput = false
		activeSessionDevice = nil
	}

	func activateSelectedDevice() async {
		let effectiveUID = effectiveDeviceUID
		guard effectiveUID != AudioDeviceManager.systemDefaultUID else {
			AppLogger.shared.deviceManager.debug("activateSelectedDevice: system default selected, skipping")
			activeSessionDevice = nil
			restoreSystemDefault()
			return
		}

		guard let device = availableDevices.first(where: { $0.uid == effectiveUID }) else {
			AppLogger.shared.deviceManager.error("activateSelectedDevice: device \(effectiveUID) not found in \(availableDevices.map { "\($0.name):\($0.uid)" })")
			restoreSystemDefault()
			return
		}

		let currentDefault = getSystemDefaultInputDeviceID()
		let currentDefaultName = currentDefault.flatMap { getDeviceName(for: $0) } ?? "unknown"
		AppLogger.shared.deviceManager.info("activateSelectedDevice: current default=\(currentDefaultName) (ID: \(currentDefault ?? 0)), switching to \(device.name) (ID: \(device.id))")

		if savedSystemDefaultDeviceID == nil {
			savedSystemDefaultDeviceID = currentDefault
		}
		let originalDefault = savedSystemDefaultDeviceID
		activeSessionDevice = device

		let targetDeviceID = device.id
		let targetDeviceName = device.name
		await Task.detached(priority: .userInitiated) {
			Self.setSystemDefaultInputDeviceSync(targetDeviceID)
		}.value

		// The recording stopped while the switch was in flight and already restored the
		// default, so this late switch would otherwise leave the system on our device
		if Task.isCancelled, savedSystemDefaultDeviceID == nil, let originalDefault {
			AppLogger.shared.deviceManager.info("activateSelectedDevice: cancelled mid-switch, restoring original default")
			activeSessionDevice = nil
			setSystemDefaultInputDevice(originalDefault)
			return
		}

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
		let effectiveUID = effectiveDeviceUID
		if effectiveUID == AudioDeviceManager.systemDefaultUID {
			AppLogger.shared.deviceManager.debug("resolveActiveDeviceID → nil (system default)")
			return nil
		}

		guard let device = availableDevices.first(where: { $0.uid == effectiveUID }) else {
			AppLogger.shared.deviceManager.info(
				"Device \(effectiveUID) not available, falling back to system default")
			return nil
		}

		AppLogger.shared.deviceManager.info("resolveActiveDeviceID → \(device.name) (ID: \(device.id), UID: \(device.uid))")
		activeSessionDevice = device
		return device.id
	}

	/// Number of input channels the device exposes; `systemDefaultUID` means the
	/// current default input. Returns 0 when the device is unknown.
	func inputChannelCount(forUID uid: String) -> Int {
		let deviceID: AudioDeviceID?
		if uid == AudioDeviceManager.systemDefaultUID {
			deviceID = getSystemDefaultInputDeviceID()
		} else {
			deviceID = availableDevices.first(where: { $0.uid == uid })?.id
		}
		guard let deviceID else { return 0 }
		return Self.inputChannelCount(for: deviceID)
	}

	/// Channel count of the device the next recording will use, which is the clamshell
	/// microphone rather than the saved one while the lid is closed.
	var effectiveInputChannelCount: Int {
		inputChannelCount(forUID: effectiveDeviceUID)
	}

	nonisolated static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreamConfiguration,
			mScope: kAudioObjectPropertyScopeInput,
			mElement: kAudioObjectPropertyElementMain
		)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
			return 0
		}

		let raw = UnsafeMutableRawPointer.allocate(
			byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
		defer { raw.deallocate() }
		let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
		guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
			return 0
		}
		return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
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
				guard let self else { return }
				self.refreshDevices()
				NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
				self.reportLostSessionDevice()
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

	private func reportLostSessionDevice() {
		guard let device = activeSessionDevice,
			!availableDevices.contains(where: { $0.uid == device.uid })
		else { return }
		AppLogger.shared.deviceManager.error("Input device disconnected mid-recording: \(device.name)")
		NotificationCenter.default.post(
			name: .activeInputDeviceLost, object: nil, userInfo: ["name": device.name])
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

enum InputDeviceResolver {
	static func effectiveUID(
		persistedUID: String,
		clamshellUID: String,
		isLidClosed: Bool,
		fallbackToSystemDefault: Bool = false,
		availableUIDs: Set<String>
	) -> String {
		if fallbackToSystemDefault { return AudioDeviceManager.systemDefaultUID }
		if isLidClosed, !clamshellUID.isEmpty, availableUIDs.contains(clamshellUID) {
			return clamshellUID
		}
		return persistedUID
	}
}

enum ClamshellDetector {
	/// Reads `AppleClamshellState` from the power-management root domain, which is
	/// true while a laptop lid is shut (clamshell mode with an external display).
	static func isLidClosed() -> Bool {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
		guard service != IO_OBJECT_NULL else { return false }
		defer { IOObjectRelease(service) }

		guard
			let value = IORegistryEntryCreateCFProperty(
				service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue()
		else { return false }
		return (value as? Bool) ?? false
	}

	/// Desktops have no clamshell state at all, so the setting is only offered on laptops.
	static var hasLid: Bool {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
		guard service != IO_OBJECT_NULL else { return false }
		defer { IOObjectRelease(service) }
		guard
			let value = IORegistryEntryCreateCFProperty(
				service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
		else { return false }
		value.release()
		return true
	}
}
