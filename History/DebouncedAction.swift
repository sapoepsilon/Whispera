import Foundation

/// Runs the latest scheduled action once input has been quiet for `delay`, so a burst of
/// Stepper clicks applies once instead of on every intermediate value.
@MainActor
final class DebouncedAction {
	private let delay: Duration
	private var task: Task<Void, Never>?
	private var action: (() -> Void)?

	init(delay: Duration) {
		self.delay = delay
	}

	var isPending: Bool { action != nil }

	func schedule(_ action: @escaping () -> Void) {
		self.action = action
		task?.cancel()
		task = Task { [weak self, delay] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled else { return }
			self?.flush()
		}
	}

	/// Runs a pending action now, e.g. when the view that scheduled it goes away.
	func flush() {
		task?.cancel()
		task = nil
		let pending = action
		action = nil
		pending?()
	}

	func cancel() {
		task?.cancel()
		task = nil
		action = nil
	}
}
