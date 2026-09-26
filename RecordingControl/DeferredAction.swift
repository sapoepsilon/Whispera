import Foundation

/// A single cancellable delayed action; scheduling again replaces the pending one.
@MainActor
final class DeferredAction {
	private var task: Task<Void, Never>?
	private var generation = 0

	var isScheduled: Bool { task != nil }

	func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () async -> Void) {
		cancel()
		generation += 1
		let scheduledGeneration = generation
		task = Task { @MainActor [weak self] in
			if delay > 0 {
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
