import Foundation

/// A single cancellable delayed action; scheduling again replaces the pending one.
@MainActor
final class DeferredAction {
	typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

	static let taskSleep: Sleeper = { delay in
		try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
	}

	private var task: Task<Void, Never>?
	private var generation = 0
	private let sleep: Sleeper

	/// - Parameter sleep: waits out the delay; tests inject a manual clock here.
	init(sleep: @escaping Sleeper = DeferredAction.taskSleep) {
		self.sleep = sleep
	}

	var isScheduled: Bool { task != nil }

	func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () async -> Void) {
		cancel()
		generation += 1
		let scheduledGeneration = generation
		let sleep = sleep
		task = Task { @MainActor [weak self] in
			if delay > 0 {
				try? await sleep(delay)
			}
			guard !Task.isCancelled, let self, self.generation == scheduledGeneration else { return }
			self.task = nil
			await action()
		}
	}

	func cancel() {
		task?.cancel()
		task = nil
	}
}

/// Keeps capturing for a short tail after a stop request so the last syllable is not
/// clipped. Repeated stop requests during the tail are ignored, and cancelling the
/// recording drops the pending stop.
@MainActor
final class TailStopCoordinator {
	private let timer: DeferredAction
	private(set) var isFinalizing = false

	init(timer: DeferredAction? = nil) {
		self.timer = timer ?? DeferredAction()
	}

	/// Returns false when a stop is already pending and this request was ignored.
	@discardableResult
	func requestStop(tail: TimeInterval, stop: @escaping @MainActor () -> Void) -> Bool {
		guard !isFinalizing else { return false }
		guard tail > 0 else {
			stop()
			return true
		}
		isFinalizing = true
		timer.schedule(after: tail) { [weak self] in
			guard let self, self.isFinalizing else { return }
			self.isFinalizing = false
			stop()
		}
		return true
	}

	func cancel() {
		timer.cancel()
		isFinalizing = false
	}
}
