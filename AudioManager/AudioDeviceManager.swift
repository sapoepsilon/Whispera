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
	/// kAudioDevicePropertyDeviceIsAlive: false once the hardware stops working while still listed.
	var isAlive = true
	/// kAudioDevicePropertyDeviceIsRunningSomewhere: some process is doing IO on it right now.
	var isRunningSomewhere = false

	/// Devices fed by software rather than a microphone; exact zeros from them are normal.
	var isVirtualOrAggregate: Bool {
		transportType == kAudioDeviceTransportTypeVirtual
			|| transportType == kAudioDeviceTransportTypeAggregate
			|| transportType == kAudioDeviceTransportTypeAutoAggregate
	}

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

extension AudioInputDevice {
	/// Aggregates Core Audio or Apple frameworks create for their own use, never ones a person made.
	/// AVAudioEngine builds "CADefaultDeviceAggregate-<pid>-<n>" for Whispera's own process while it
	/// records, and voice-processing I/O builds "VPAUAggregateAudioDevice-...".
	static let internalAggregatePrefixes = ["CADefaultDeviceAggregate", "VPAUAggregateAudioDevice"]

	/// Whether a device is plumbing that must not be offered as a microphone: an aggregate with one of
	/// the internal name/UID prefixes above (whatever transport it reports), or any aggregate marked
	/// private, which exists only inside the process that made it. Virtual devices (BlackHole,
	/// Loopback) and the public aggregates people build in Audio MIDI Setup stay listed.
	static func isInternal(
		uid: String, name: String, transportType: UInt32, isPrivateAggregate: Bool
	) -> Bool {
		if internalAggregatePrefixes.contains(where: { uid.hasPrefix($0) || name.hasPrefix($0) }) {
			return true
		}
		let isAggregate =
			transportType == kAudioDeviceTransportTypeAggregate
			|| transportType == kAudioDeviceTransportTypeAutoAggregate
		return isAggregate && isPrivateAggregate
	}
}

extension Notification.Name {
	static let audioDevicesChanged = Notification.Name("AudioDevicesChanged")
	static let audioInputDeviceChanged = Notification.Name("AudioInputDeviceChanged")
	static let devicePickerToggled = Notification.Name("DevicePickerToggled")
	static let devicePickerDismissed = Notification.Name("DevicePickerDismissed")
	static let activeInputDeviceLost = Notification.Name("ActiveInputDeviceLost")
	static let inputFallbackEngaged = Notification.Name("InputFallbackEngaged")
}

@MainActor
@Observable
final class AudioDeviceManager {
	static let shared = AudioDeviceManager()
	nonisolated static let systemDefaultUID = "system-default"

	private(set) var availableDevices: [AudioInputDevice] = []
	private(set) var selectedDevice: AudioInputDevice?
	/// True while a recording runs on another input because its own vanished or went silent.
	var isUsingFallbackInput: Bool { sessionFallbackUID != nil }
	/// The input the current recording moved to and why; drives the pill and menu bar note.
	private(set) var sessionFallback: InputFallback?
	@ObservationIgnored
	private var sessionFallbackUID: String?
	@ObservationIgnored
	private(set) var activeSessionDevice: AudioInputDevice?

	// Precomputed device the app is actually recording from (the explicit
	// selection, or the system default when none is chosen). Recomputed only on
	// selection/enumeration changes so views avoid an O(n) scan per render.
	private(set) var activeDevice: AudioInputDevice?

	nonisolated static let persistedDeviceKey = "selectedAudioInputDeviceUID"
	nonisolated static let clamshellDeviceKey = "clamshellAudioInputDeviceUID"

	@ObservationIgnored
	private let defaults: UserDefaults
	@ObservationIgnored
	private let provider: AudioInputDeviceProviding

	var persistedDeviceUID: String {
		get { defaults.string(forKey: Self.persistedDeviceKey) ?? Self.systemDefaultUID }
		set { defaults.set(newValue, forKey: Self.persistedDeviceKey) }
	}

	var clamshellDeviceUID: String {
		get { defaults.string(forKey: Self.clamshellDeviceKey) ?? "" }
		set { defaults.set(newValue, forKey: Self.clamshellDeviceKey) }
	}

	var isAutoSwitchEnabled: Bool {
		AutoInputSwitchSettings.isEnabled(in: defaults)
	}

	/// The last input that delivered sound, tried before any other fallback.
	var lastWorkingDeviceUID: String? {
		defaults.string(forKey: AutoInputSwitchSettings.lastWorkingDeviceKey)
	}

	@ObservationIgnored
	private var silentInputs = SilentInputRegistry()
	/// Names of every input seen this run, so a missing one can still be named in a notice.
	@ObservationIgnored
	private var knownDeviceNames: [String: String] = [:]
	@ObservationIgnored
	private var deviceStateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
	@ObservationIgnored
	private let listensToHardware: Bool

	@ObservationIgnored
	private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
	@ObservationIgnored
	private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
	@ObservationIgnored
	private var savedSystemDefaultDeviceID: AudioDeviceID?
	@ObservationIgnored
	private var refreshGeneration = 0

	private init() {
		defaults = .standard
		provider = CoreAudioInputDeviceProvider()
		listensToHardware = true
		publish(provider.inputDevices())
		installDeviceChangeListeners()
		applyPersistedSelection()
	}

	// For testing
	init(
		forTesting: Bool, provider: AudioInputDeviceProviding = CoreAudioInputDeviceProvider(),
		defaults: UserDefaults = .standard
	) {
		self.defaults = defaults
		self.provider = provider
		listensToHardware = false
		publish(provider.inputDevices())
		applyPersistedSelection()
	}

	// MARK: - Public API

	/// Enumerating CoreAudio devices makes blocking `AudioObjectGetPropertyData` calls that can
	/// stall for seconds while a Continuity or wireless mic is mid-transition, which is exactly
	/// when the HAL fires the change listeners. The enumeration runs off the main actor and only
	/// the newest result is published, so a flood of notifications never freezes the UI. WHI-54
	func refreshDevices() async {
		refreshGeneration &+= 1
		let generation = refreshGeneration
		let provider = provider
		let devices = await Task.detached(priority: .userInitiated) {
			provider.inputDevices()
		}.value
		guard generation == refreshGeneration else { return }
		publish(devices)
	}

	private func publish(_ devices: [AudioInputDevice]) {
		let previous = Dictionary(availableDevices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
		for device in devices {
			knownDeviceNames[device.uid] = device.name
			// A microphone that reconnects or comes back to life gets another chance
			if let before = previous[device.uid], before.isAlive == device.isAlive {
				continue
			}
			silentInputs.forgive(device.uid)
		}
		availableDevices = devices
		applyPersistedSelection()
		if listensToHardware {
			syncDeviceStateListeners()
		}
		AppLogger.shared.deviceManager.debug("Refreshed devices: \(availableDevices.map(\.name))")
	}

	func selectDevice(uid: String) {
		persistedDeviceUID = uid
		if let name = availableDevices.first(where: { $0.uid == uid })?.name {
			defaults.set(name, forKey: AutoInputSwitchSettings.selectedDeviceNameKey)
		}
		silentInputs.forgive(uid)
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
			fallbackUID: sessionFallbackUID,
			availableUIDs: Set(availableDevices.map(\.uid))
		)
	}

	/// Moves the current recording to the system default input without touching
	/// the saved device choice, which comes back for the next recording.
	func beginFallbackToSystemDefault() {
		sessionFallbackUID = AudioDeviceManager.systemDefaultUID
		activeSessionDevice = nil
		restoreSystemDefault()
	}

	func endRecordingSession() {
		sessionFallbackUID = nil
		sessionFallback = nil
		activeSessionDevice = nil
	}

	/// The device the recording would use with no fallback: the saved choice, or the clamshell mic.
	private var preferredDeviceUID: String {
		InputDeviceResolver.effectiveUID(
			persistedUID: persistedDeviceUID,
			clamshellUID: clamshellDeviceUID,
			isLidClosed: !clamshellDeviceUID.isEmpty && ClamshellDetector.isLidClosed(),
			availableUIDs: Set(availableDevices.map(\.uid))
		)
	}

	private var namesForNotices: [String: String] {
		var names = knownDeviceNames
		if names[persistedDeviceUID] == nil,
			let saved = defaults.string(forKey: AutoInputSwitchSettings.selectedDeviceNameKey)
		{
			names[persistedDeviceUID] = saved
		}
		return names
	}

	/// Run when a recording starts. Uses the device list the Core Audio listeners keep current, so
	/// starting a recording never waits on the HAL. Returns the fallback when the preferred input
	/// is missing, not alive, or recently silent; the saved choice is untouched and comes back
	/// for the next recording that finds it working.
	@discardableResult
	func planSessionInput() -> InputFallback? {
		guard isAutoSwitchEnabled, sessionFallbackUID == nil else { return nil }
		let preferred = preferredDeviceUID
		let plan = InputFailoverPlanner.plan(
			preferredUID: preferred, devices: availableDevices, unusableUIDs: silentInputs.silentUIDs(),
			lastWorkingUID: lastWorkingDeviceUID, knownNames: namesForNotices)
		return apply(plan, context: "recording start, preferred \(preferred)")
	}

	/// Moves a recording whose input was unplugged. With automatic switching off it keeps the old
	/// behavior of following the system default.
	@discardableResult
	func beginFallback(afterLosing lost: AudioInputDevice?) -> InputFallback? {
		guard isAutoSwitchEnabled else {
			beginFallbackToSystemDefault()
			return nil
		}
		activeSessionDevice = nil
		restoreSystemDefault()
		let lostUID = lost?.uid ?? preferredDeviceUID
		var names = namesForNotices
		if let lost { names[lost.uid] = lost.name }
		let plan = InputFailoverPlanner.plan(
			preferredUID: lostUID, devices: availableDevices,
			unusableUIDs: silentInputs.silentUIDs().union([lostUID]),
			lastWorkingUID: lastWorkingDeviceUID, knownNames: names, reasonOverride: .disconnected)
		if apply(plan, context: "lost \(lost?.name ?? lostUID)", force: true) == nil {
			sessionFallbackUID = AudioDeviceManager.systemDefaultUID
		}
		return sessionFallback
	}

	/// The input the recording is capturing from right now.
	var currentInputDevice: AudioInputDevice? {
		let uid = effectiveDeviceUID
		if uid != AudioDeviceManager.systemDefaultUID,
			let device = availableDevices.first(where: { $0.uid == uid })
		{
			return device
		}
		return availableDevices.first(where: \.isDefault)
	}

	/// The open input delivered only digital silence: skip it for a while and pick another.
	/// Returns nil when nothing else can be tried, and the recording stays where it is.
	func markInputSilent(_ device: AudioInputDevice) -> InputFallback? {
		silentInputs.markSilent(device.uid)
		AppLogger.shared.deviceManager.error("Input \(device.name) delivered no signal; skipping it for a while")
		let plan = InputFailoverPlanner.plan(
			preferredUID: device.uid, devices: availableDevices, unusableUIDs: silentInputs.silentUIDs(),
			lastWorkingUID: lastWorkingDeviceUID, knownNames: namesForNotices, reasonOverride: .silent)
		let previous = sessionFallback
		guard let fallback = apply(plan, context: "silent \(device.name)", force: true) else { return nil }
		// The notice keeps naming the microphone the user picked when that is the one that failed first
		if let previous, let original = previous.unavailableName {
			let merged = InputFallback(
				uid: fallback.uid, name: fallback.name, reason: previous.reason, unavailableName: original)
			sessionFallback = merged
			return merged
		}
		return fallback
	}

	func markInputWorking(_ device: AudioInputDevice) {
		guard lastWorkingDeviceUID != device.uid else { return }
		defaults.set(device.uid, forKey: AutoInputSwitchSettings.lastWorkingDeviceKey)
		AppLogger.shared.deviceManager.debug("Last working input is now \(device.name)")
	}

	private func apply(_ plan: InputFailoverPlanner.Plan, context: String, force: Bool = false) -> InputFallback? {
		switch plan {
		case .usePreferred:
			return nil
		case .noWorkingInput:
			AppLogger.shared.deviceManager.error("No working input to switch to (\(context))")
			return nil
		case .fallback(let fallback):
			guard force || sessionFallbackUID == nil else { return nil }
			// Following the system default keeps a kept-open stream on it reusable
			let isDefault = availableDevices.first(where: { $0.uid == fallback.uid })?.isDefault ?? false
			sessionFallbackUID = isDefault ? AudioDeviceManager.systemDefaultUID : fallback.uid
			sessionFallback = fallback
			activeSessionDevice = nil
			AppLogger.shared.deviceManager.info(
				"Auto-switching input to \(fallback.name) (\(fallback.uid)), reason: \(String(describing: fallback.reason)), unavailable: \(fallback.unavailableName ?? "unknown") (\(context))"
			)
			return fallback
		}
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

		let currentDefault = Self.getSystemDefaultInputDeviceID()
		let currentDefaultName = currentDefault.flatMap { Self.getDeviceName(for: $0) } ?? "unknown"
		AppLogger.shared.deviceManager.info("activateSelectedDevice: current default=\(currentDefaultName) (ID: \(currentDefault ?? 0)), switching to \(device.name) (ID: \(device.id))")

		// Already the system default, so there is nothing to switch: skips a redundant CoreAudio
		// call that blocks for seconds on Continuity and wireless mics. WHI-54
		if currentDefault == device.id {
			AppLogger.shared.deviceManager.debug("activateSelectedDevice: \(device.name) already default, skipping switch")
			activeSessionDevice = device
			return
		}

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

		let newDefault = Self.getSystemDefaultInputDeviceID()
		let newDefaultName = newDefault.flatMap { Self.getDeviceName(for: $0) } ?? "unknown"
		if newDefault == targetDeviceID {
			AppLogger.shared.deviceManager.info("activateSelectedDevice: verified system default changed to \(newDefaultName)")
		} else {
			AppLogger.shared.deviceManager.error("activateSelectedDevice: FAILED - system default is still \(newDefaultName) (ID: \(newDefault ?? 0)), expected \(targetDeviceName) (ID: \(targetDeviceID))")
		}
	}

	func restoreSystemDefault() {
		guard let original = savedSystemDefaultDeviceID else { return }
		setSystemDefaultInputDevice(original)
		let name = Self.getDeviceName(for: original) ?? "unknown"
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

	/// The device a recording in progress should be capturing from right now, resolved without the
	/// logging and session bookkeeping of `resolveActiveDeviceID`, so it can be polled.
	func expectedInputDeviceID() -> AudioDeviceID? {
		let effectiveUID = effectiveDeviceUID
		if effectiveUID != AudioDeviceManager.systemDefaultUID,
			let device = availableDevices.first(where: { $0.uid == effectiveUID })
		{
			return device.id
		}
		return Self.getSystemDefaultInputDeviceID()
	}

	func deviceName(forID deviceID: AudioDeviceID) -> String? {
		availableDevices.first(where: { $0.id == deviceID })?.name ?? Self.getDeviceName(for: deviceID)
	}

	/// Number of input channels the device exposes; `systemDefaultUID` means the
	/// current default input. Returns 0 when the device is unknown.
	func inputChannelCount(forUID uid: String) -> Int {
		let deviceID: AudioDeviceID?
		if uid == AudioDeviceManager.systemDefaultUID {
			deviceID = Self.getSystemDefaultInputDeviceID()
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
			activeDevice = availableDevices.first(where: \.isDefault)
		} else {
			selectedDevice = availableDevices.first(where: { $0.uid == persistedDeviceUID })
			activeDevice = selectedDevice ?? availableDevices.first(where: \.isDefault)
		}
	}

	nonisolated static func enumerateInputDevices() -> [AudioInputDevice] {
		enumerateInputDevices(defaultDeviceID: getSystemDefaultInputDeviceID())
	}

	private nonisolated static func enumerateInputDevices(defaultDeviceID: AudioDeviceID?) -> [AudioInputDevice] {
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
			guard Self.isInputDevice(deviceID),
				let uid = Self.getDeviceUID(for: deviceID),
				let name = Self.getDeviceName(for: deviceID)
			else { continue }
			let transportType = Self.getDeviceTransportType(for: deviceID)
			guard
				!AudioInputDevice.isInternal(
					uid: uid, name: name, transportType: transportType,
					isPrivateAggregate: Self.isPrivateAggregate(deviceID))
			else { continue }

			devices.append(
				AudioInputDevice(
					id: deviceID,
					uid: uid,
					name: name,
					isDefault: deviceID == defaultDeviceID,
					transportType: transportType,
					isAlive: Self.readFlag(kAudioDevicePropertyDeviceIsAlive, of: deviceID) ?? true,
					isRunningSomewhere: Self.readFlag(kAudioDevicePropertyDeviceIsRunningSomewhere, of: deviceID)
						?? false
				))
		}

		return devices
	}

	private nonisolated static func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
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

	private nonisolated static func getDeviceUID(for deviceID: AudioDeviceID) -> String? {
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

	private nonisolated static func getDeviceName(for deviceID: AudioDeviceID) -> String? {
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

	private nonisolated static func readFlag(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID)
		-> Bool?
	{
		var value: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: selector,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
		return value != 0
	}

	/// Reads kAudioAggregateDeviceIsPrivateKey from the composition; false for anything that is not an aggregate.
	private nonisolated static func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
		var composition: Unmanaged<CFDictionary>?
		var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioAggregateDevicePropertyComposition,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		guard AudioObjectHasProperty(deviceID, &address),
			AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &composition) == noErr,
			let dictionary = composition?.takeRetainedValue() as? [String: Any]
		else { return false }
		return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
	}

	private nonisolated static func getDeviceTransportType(for deviceID: AudioDeviceID) -> UInt32 {
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

	private nonisolated static func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
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
				await self.refreshDevices()
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
				await self?.refreshDevices()
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
		guard let device = activeSessionDevice else { return }
		let current = availableDevices.first(where: { $0.uid == device.uid })
		if let current, current.isAlive { return }
		AppLogger.shared.deviceManager.error(
			"Input device \(current == nil ? "disconnected" : "stopped responding") mid-recording: \(device.name)")
		NotificationCenter.default.post(
			name: .activeInputDeviceLost, object: nil, userInfo: ["name": device.name, "device": device])
	}

	/// Each input gets listeners for going dead and for starting or stopping IO anywhere, so the
	/// cached list the fallback planner reads is current without probing at recording start.
	private func syncDeviceStateListeners() {
		let current = Set(availableDevices.map(\.id))
		for (deviceID, block) in deviceStateListeners where !current.contains(deviceID) {
			for selector in Self.deviceStateSelectors {
				var address = AudioObjectPropertyAddress(
					mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
				AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
			}
			deviceStateListeners[deviceID] = nil
		}
		for deviceID in current where deviceStateListeners[deviceID] == nil {
			let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
				Task { @MainActor in
					guard let self else { return }
					await self.refreshDevices()
					self.reportLostSessionDevice()
				}
			}
			for selector in Self.deviceStateSelectors {
				var address = AudioObjectPropertyAddress(
					mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
				AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
			}
			deviceStateListeners[deviceID] = block
		}
	}

	private static let deviceStateSelectors: [AudioObjectPropertySelector] = [
		kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunningSomewhere,
	]

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
		fallbackUID: String? = nil,
		availableUIDs: Set<String>
	) -> String {
		if let fallbackUID { return fallbackUID }
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
