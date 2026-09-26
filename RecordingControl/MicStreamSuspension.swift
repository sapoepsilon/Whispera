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
