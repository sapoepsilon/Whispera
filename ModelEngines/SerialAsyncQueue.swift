import Foundation

/// Runs async operations one at a time, in the order they were submitted, even though each
/// operation suspends. A failed or cancelled operation does not block the ones queued after it.
@MainActor
final class SerialAsyncQueue {
	private var tail: Task<Void, Never>?

	func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
		let previous = tail
		let task = Task { @MainActor () async throws -> T in
			await previous?.value
			try Task.checkCancellation()
			return try await operation()
		}
		tail = Task { @MainActor in _ = try? await task.value }
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}
}
