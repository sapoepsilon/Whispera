import Foundation
import Testing

@testable import Whispera

@MainActor
struct ModelOperationQueueTests {
	/// Holds an operation open until the test lets it finish.
	final class Gate {
		private var continuation: CheckedContinuation<Void, Never>?
		private(set) var isWaiting = false

		func wait() async {
			await withCheckedContinuation { continuation in
				self.continuation = continuation
				isWaiting = true
			}
		}

		func open() {
			isWaiting = false
			continuation?.resume()
			continuation = nil
		}
	}

	private func yieldUntil(_ condition: () -> Bool) async {
		for _ in 0..<1000 where !condition() {
			await Task.yield()
		}
	}

	@Test func operationsRunOneAtATime() async throws {
		let queue = ModelOperationQueue()
		let gate = Gate()
		var log: [String] = []

		let first = Task { try await queue.run { log.append("A start"); await gate.wait(); log.append("A end") } }
		await yieldUntil { gate.isWaiting }
		let second = Task { try await queue.run { log.append("B") } }
		for _ in 0..<50 { await Task.yield() }
		#expect(log == ["A start"], "B started while A was still running")

		gate.open()
		try await first.value
		try await second.value
		#expect(log == ["A start", "A end", "B"])
		#expect(!queue.isBusy)
	}

	/// Cancel used to drop the lock at once, so a model picked right after started loading next to the
	/// cancelled one, and the cancelled one's cleanup then cleared the new operation's handle.
	@Test func cancelledOperationKeepsTheLockUntilItUnwinds() async throws {
		let queue = ModelOperationQueue()
		let gate = Gate()
		var log: [String] = []

		let first = Task {
			try await queue.run {
				log.append("A start")
				await gate.wait()
				log.append("A unwinding")
				try Task.checkCancellation()
				log.append("A loaded")
			}
		}
		await yieldUntil { gate.isWaiting }
		#expect(queue.cancelCurrent())
		#expect(queue.isBusy, "The lock was released before the cancelled operation finished")

		let secondGate = Gate()
		let second = Task { try await queue.run { log.append("B start"); await secondGate.wait(); log.append("B end") } }
		for _ in 0..<50 { await Task.yield() }
		#expect(log == ["A start"])

		gate.open()
		await #expect(throws: CancellationError.self) { try await first.value }
		await yieldUntil { secondGate.isWaiting }
		#expect(log == ["A start", "A unwinding", "B start"])
		#expect(queue.isBusy, "A's cleanup released B's slot")

		secondGate.open()
		try await second.value
		#expect(!queue.isBusy)
	}

	@Test func aFailedOperationDoesNotFailTheOneWaitingBehindIt() async throws {
		struct Failure: Error {}
		let queue = ModelOperationQueue()
		let gate = Gate()
		var ranSecond = false

		let first = Task { try await queue.run { await gate.wait(); throw Failure() } }
		await yieldUntil { gate.isWaiting }
		let second = Task { try await queue.run { ranSecond = true } }
		gate.open()

		await #expect(throws: Failure.self) { try await first.value }
		try await second.value
		#expect(ranSecond)
	}

	@Test func cancelWithNothingRunningReportsFalse() {
		#expect(!ModelOperationQueue().cancelCurrent())
	}
}
