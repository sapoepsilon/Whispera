import CoreAudio
import Foundation

/// Lists the inputs Core Audio offers. Every call can block on the HAL for seconds while a
/// Continuity or wireless mic is mid-transition, so callers run it off the main actor.
protocol AudioInputDeviceProviding: Sendable {
	func inputDevices() -> [AudioInputDevice]
}

struct CoreAudioInputDeviceProvider: AudioInputDeviceProviding {
	func inputDevices() -> [AudioInputDevice] {
		AudioDeviceManager.enumerateInputDevices()
	}
}

enum AutoInputSwitchSettings {
	static let enabledKey = "autoSwitchAudioInput"
	static let defaultEnabled = true
	static let lastWorkingDeviceKey = "lastWorkingAudioInputDeviceUID"
	static let selectedDeviceNameKey = "selectedAudioInputDeviceName"

	static func isEnabled(in defaults: UserDefaults) -> Bool {
		defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
	}
}

/// Why a recording is not using the microphone the user picked.
enum InputFallbackReason: Equatable, Sendable {
	/// Not connected when the recording started.
	case missing
	/// Listed by Core Audio but reporting itself as not alive.
	case notResponding
	/// Open but delivering nothing but digital silence.
	case silent
	/// Unplugged while the recording ran.
	case disconnected
}

/// The input a recording moved to, and the sentence that tells the user why.
struct InputFallback: Equatable, Sendable {
	let uid: String
	let name: String
	let reason: InputFallbackReason
	/// The microphone that could not be used; nil when its name was never seen.
	let unavailableName: String?

	var notice: String {
		guard let unavailableName else {
			return String(localized: "Using \(name) — your selected microphone isn't available.")
		}
		switch reason {
		case .missing:
			return String(localized: "Using \(name) — \(unavailableName) isn't connected.")
		case .notResponding:
			return String(localized: "Using \(name) — \(unavailableName) isn't responding.")
		case .silent:
			return String(localized: "Using \(name) — \(unavailableName) isn't picking up any sound.")
		case .disconnected:
			return String(localized: "Using \(name) — \(unavailableName) disconnected.")
		}
	}

	static func noWorkingInputNotice(silentDevice name: String) -> String {
		String(localized: "\(name) isn't picking up any sound, and no other microphone is available.")
	}
}

/// Picks the input a recording should use when the preferred one cannot work. Order: the user's
/// choice, then the system default, then the last microphone that delivered sound, then any other
/// live hardware input (built-in first, then ones already running somewhere). Virtual devices and
/// aggregates are only used when they are the default or the last working input, because one that
/// nothing feeds records silence forever.
enum InputFailoverPlanner {
	enum Plan: Equatable {
		case usePreferred
		case fallback(InputFallback)
		case noWorkingInput
	}

	static func plan(
		preferredUID: String,
		devices: [AudioInputDevice],
		unusableUIDs: Set<String> = [],
		lastWorkingUID: String?,
		knownNames: [String: String] = [:],
		reasonOverride: InputFallbackReason? = nil
	) -> Plan {
		func isUsable(_ device: AudioInputDevice) -> Bool {
			device.isAlive && !unusableUIDs.contains(device.uid)
		}

		let systemDefault = devices.first(where: \.isDefault)
		let preferred: AudioInputDevice? =
			preferredUID == AudioDeviceManager.systemDefaultUID
			? systemDefault : devices.first(where: { $0.uid == preferredUID })

		if let preferred, isUsable(preferred) { return .usePreferred }
		// No default input at all means Core Audio has nothing to offer either
		if preferred == nil, preferredUID == AudioDeviceManager.systemDefaultUID, devices.isEmpty {
			return .noWorkingInput
		}

		let reason: InputFallbackReason
		if let reasonOverride {
			reason = reasonOverride
		} else if let preferred {
			reason = preferred.isAlive ? .silent : .notResponding
		} else {
			reason = .missing
		}
		let unavailableName = preferred?.name ?? knownNames[preferredUID]

		var ordered: [AudioInputDevice] = []
		if let systemDefault { ordered.append(systemDefault) }
		if let lastWorkingUID, let lastWorking = devices.first(where: { $0.uid == lastWorkingUID }) {
			ordered.append(lastWorking)
		}
		let hardware = devices.filter { !$0.isVirtualOrAggregate }
		ordered += hardware.filter { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
		ordered += hardware.filter { $0.transportType != kAudioDeviceTransportTypeBuiltIn && $0.isRunningSomewhere }
		ordered += hardware

		guard
			let choice = ordered.first(where: { isUsable($0) && $0.uid != preferred?.uid })
		else { return .noWorkingInput }
		return .fallback(
			InputFallback(uid: choice.uid, name: choice.name, reason: reason, unavailableName: unavailableName))
	}
}

/// Inputs that were open but delivered only digital silence. They are skipped for a while so every
/// recording does not lose its first seconds to the same dead microphone, and forgiven as soon as
/// they reconnect or report a change in state.
struct SilentInputRegistry {
	static let quarantine: TimeInterval = 10 * 60

	private var silentUntil: [String: Date] = [:]

	mutating func markSilent(_ uid: String, now: Date = Date()) {
		silentUntil[uid] = now.addingTimeInterval(Self.quarantine)
	}

	mutating func forgive(_ uid: String) {
		silentUntil[uid] = nil
	}

	func silentUIDs(now: Date = Date()) -> Set<String> {
		Set(silentUntil.filter { $0.value > now }.map(\.key))
	}
}

/// Decides, from the first seconds of a recording, whether its input delivers any signal at all.
/// A real microphone always has a noise floor well above -120 dBFS, so only true digital silence
/// (or no audio arriving) counts; a quiet room never does.
struct InputSignalProbe {
	enum Verdict: Equatable {
		case listening
		case heard
		case silent
		/// Not judged: virtual devices legitimately deliver exact zeros while nothing feeds them.
		case exempt
	}

	static let window: TimeInterval = 2
	static let silenceThreshold: Float = 1e-6

	private(set) var verdict: Verdict = .listening
	private var armedAt: Date?

	var isArmed: Bool { armedAt != nil }

	mutating func reset() {
		verdict = .listening
		armedAt = nil
	}

	mutating func exempt() {
		verdict = .exempt
	}

	mutating func arm(at now: Date = Date()) {
		guard armedAt == nil else { return }
		armedAt = now
	}

	/// Samples count from the moment they arrive, but only `arm` starts the window, so the caller
	/// decides first whether the input is judged at all.
	mutating func ingest(peak: Float, at now: Date = Date()) {
		guard verdict == .listening else { return }
		if peak > Self.silenceThreshold {
			verdict = .heard
		}
	}

	mutating func ingest(samples: [Float], at now: Date = Date()) {
		guard verdict == .listening else { return }
		var peak: Float = 0
		for sample in samples {
			let magnitude = abs(sample)
			if magnitude > peak { peak = magnitude }
		}
		ingest(peak: peak, at: now)
	}

	@discardableResult
	mutating func evaluate(now: Date = Date()) -> Verdict {
		if verdict == .listening, let armedAt, now.timeIntervalSince(armedAt) >= Self.window {
			verdict = .silent
		}
		return verdict
	}
}
