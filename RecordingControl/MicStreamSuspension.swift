import Foundation

/// Reasons an idle, kept-open microphone stream must close even though the policy
/// says to keep it open. An open input stream holds a CoreAudio IO power assertion
/// that stops the Mac from idle-sleeping and keeps the mic indicator on.
struct MicStreamSuspension: Equatable {
	enum Reason: String, CaseIterable {
		case systemSleep
		case displaySleep
		case screenLocked
		case sessionInactive
		case lowPowerMode
	}

	private(set) var reasons: Set<Reason> = []

	var isSuspended: Bool { !reasons.isEmpty }

	/// Returns true when this call suspended a stream that was allowed to stay open.
	@discardableResult
	mutating func begin(_ reason: Reason) -> Bool {
		let wasSuspended = isSuspended
		reasons.insert(reason)
		return !wasSuspended
	}

	/// Returns true when the last reason cleared and the policy should be re-applied.
	@discardableResult
	mutating func end(_ reason: Reason) -> Bool {
		guard reasons.remove(reason) != nil else { return false }
		return !isSuspended
	}

	/// Waking the machine implies the display and session are back too.
	@discardableResult
	mutating func endAfterWake() -> Bool {
		let wasSuspended = isSuspended
		reasons.subtract([.systemSleep, .displaySleep])
		return wasSuspended && !isSuspended
	}

	static func allowsKeepingOpen(policy: MicStreamPolicy, suspension: MicStreamSuspension) -> Bool {
		policy != .onDemand && !suspension.isSuspended
	}
}

/// Something outside the user's control that affects a recording in progress.
enum CaptureInterruption: Equatable {
	/// AVAudioEngine posted a configuration change, or was found stopped on its own: a Bluetooth
	/// profile switch, a sample-rate change, a new default input, an aggregate device rebuilding.
	case engineStopped
	/// The device the recording should use is no longer the one the stream is open on, for example
	/// the lid closed and a clamshell microphone is configured.
	case inputDeviceChanged
	case systemSleep
	/// Fast user switching moved this session to the background.
	case sessionResigned
	case captureLimitReached
}

enum CaptureInterruptionResponse: Equatable {
	case ignore
	/// Reopen the input and keep the samples captured so far.
	case restartInput
	/// Stop now and transcribe what was captured, telling the user why.
	case finish(notice: String)
	/// Nothing was captured yet, so the startup is simply abandoned.
	case cancelStartup
}

/// Decides how a recording reacts to interruptions so none of them leaves the UI showing a
/// recording that no longer receives audio.
struct CaptureInterruptionPolicy {
	static let maxRestartsPerSession = 3

	private(set) var restarts = 0

	mutating func reset() {
		restarts = 0
	}

	mutating func respond(
		to interruption: CaptureInterruption, isRecording: Bool, isStarting: Bool, path: CapturePath?,
		isRestarting: Bool
	) -> CaptureInterruptionResponse {
		switch interruption {
		case .systemSleep, .sessionResigned:
			if isRecording {
				let notice =
					interruption == .systemSleep
					? String(localized: "Recording stopped because the Mac went to sleep. What was captured was transcribed.")
					: String(localized: "Recording stopped because another user took over the Mac. What was captured was transcribed.")
				return .finish(notice: notice)
			}
			return isStarting ? .cancelStartup : .ignore
		case .captureLimitReached:
			guard isRecording else { return .ignore }
			return .finish(
				notice: String(
					localized: "Recording reached the \(StreamCaptureBuffer.maxMinutes)-minute limit and was stopped. Everything up to the limit was transcribed."
				))
		case .engineStopped, .inputDeviceChanged:
			// The file and live paths do not run on Whispera's own engine
			guard path == .stream, isRecording, !isRestarting else { return .ignore }
			guard restarts < Self.maxRestartsPerSession else {
				return .finish(
					notice: String(
						localized: "The microphone kept dropping out, so the recording was stopped early. What was captured was transcribed."
					))
			}
			restarts += 1
			return .restartInput
		}
	}
}
