import Foundation

/// Identifies the current live dictation session. Startup work and decode passes capture the
/// generation they began in and drop their results once it is no longer current, so a stopped
/// session can neither open the microphone nor type into the session that replaced it.
struct LiveSessionGate: Equatable {
	private(set) var generation = 0
	private(set) var isActive = false

	mutating func begin() -> Int {
		generation += 1
		isActive = true
		return generation
	}

	/// Ends the current session; anything still holding its generation becomes stale.
	mutating func end() {
		generation += 1
		isActive = false
	}

	func isCurrent(_ candidate: Int) -> Bool {
		isActive && candidate == generation
	}
}

/// Model holds that outlive a model swap: an engine replaced while a transcription still
/// uses it is parked here and torn down only once every hold has ended.
struct DeferredEngineRelease<Engine> {
	private(set) var parked: [Engine] = []

	/// Returns the engine when it can be torn down now, or parks it while holds remain.
	mutating func release(_ engine: Engine, activeUses: Int) -> Engine? {
		guard activeUses > 0 else { return engine }
		parked.append(engine)
		return nil
	}

	/// Hands back every parked engine once no hold remains.
	mutating func drain(activeUses: Int) -> [Engine] {
		guard activeUses == 0, !parked.isEmpty else { return [] }
		defer { parked.removeAll() }
		return parked
	}
}

/// Bounds how long the idle-unload timer keeps re-checking a model that something is still
/// busy with. Every operation that clears a blocker reschedules idle unload itself, so the
/// polling only covers the short settle after it and must not run for the life of the app.
struct IdleUnloadRetryPolicy: Equatable {
	static let interval: TimeInterval = 2
	static let maxAttempts = 30

	private(set) var attempts = 0

	mutating func reset() {
		attempts = 0
	}

	/// Records one blocked attempt and says whether another is allowed.
	mutating func shouldRetry() -> Bool {
		guard attempts < Self.maxAttempts else { return false }
		attempts += 1
		return true
	}
}
