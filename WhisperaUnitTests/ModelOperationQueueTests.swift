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

	/// The r5 race: the old model was idle-unloaded, the user picked a new one (download running),
	/// and a dictation reloaded the old one. The old load used to finish last and put the old
	/// model back as current, silently undoing the switch.
	@Test func dictationReloadDuringADownloadFinishesBeforeTheNewModelLoads() async throws {
		let queue = ModelOperationQueue()
		let network = Gate()
		let oldLoad = Gate()
		var downloading = false
		var current: String?
		var loadsInFlight = 0
		var maxLoadsInFlight = 0
		var log: [String] = []

		func load(_ name: String, holdOn gate: Gate?) async {
			loadsInFlight += 1
			maxLoadsInFlight = max(maxLoadsInFlight, loadsInFlight)
			log.append("\(name) load start")
			if let gate { await gate.wait() }
			current = name
			loadsInFlight -= 1
			log.append("\(name) load end")
		}

		let download = Task {
			try await queue.run {
				downloading = true
				await network.wait()
				downloading = false
				await queue.waitForRestore()
				await load("new", holdOn: nil)
			}
		}
		await yieldUntil { network.isWaiting }

		let dictation = Task {
			try await queue.restore(
				canRunBesideCurrent: { downloading },
				isNeeded: { current == nil },
				load: { await load("old", holdOn: oldLoad) }
			)
		}
		await yieldUntil { oldLoad.isWaiting }
		#expect(queue.isRestoring, "The dictation waited for the whole download instead of reloading beside it")

		network.open()
		for _ in 0..<50 { await Task.yield() }
		#expect(!log.contains("new load start"), "The new model started loading next to the old one")

		oldLoad.open()
		try await dictation.value
		try await download.value
		#expect(log == ["old load start", "old load end", "new load start", "new load end"])
		#expect(current == "new", "The old model finishing last undid the user's switch")
		#expect(maxLoadsInFlight == 1)
		#expect(!queue.isBusy)
		#expect(!queue.isRestoring)
	}

	/// Once an operation is loading (not just downloading), a dictation waits for it and uses
	/// the model it leaves loaded instead of loading the previous one on top.
	@Test func dictationReloadWaitsForAnOperationThatIsLoading() async throws {
		let queue = ModelOperationQueue()
		let loading = Gate()
		var current: String?
		var log: [String] = []

		let switchOperation = Task {
			try await queue.run {
				log.append("new load start")
				await loading.wait()
				current = "new"
				log.append("new load end")
			}
		}
		await yieldUntil { loading.isWaiting }

		let dictation = Task {
			try await queue.restore(
				canRunBesideCurrent: { false },
				isNeeded: { current == nil },
				load: { log.append("old load"); current = "old" }
			)
		}
		for _ in 0..<50 { await Task.yield() }
		#expect(!queue.isRestoring)
		#expect(log == ["new load start"])

		loading.open()
		try await switchOperation.value
		try await dictation.value
		#expect(log == ["new load start", "new load end"], "The dictation reloaded the old model after the switch")
		#expect(current == "new")
	}

	/// With nothing running, the reload takes the slot, so a model picked meanwhile waits for it.
	@Test func dictationReloadWithNothingRunningHoldsTheSlot() async throws {
		let queue = ModelOperationQueue()
		let reload = Gate()
		var log: [String] = []

		let dictation = Task {
			try await queue.restore(
				canRunBesideCurrent: { true },
				isNeeded: { true },
				load: { log.append("old start"); await reload.wait(); log.append("old end") }
			)
		}
		await yieldUntil { reload.isWaiting }
		#expect(queue.isBusy)

		let pick = Task { try await queue.run { log.append("new") } }
		for _ in 0..<50 { await Task.yield() }
		#expect(log == ["old start"])

		reload.open()
		try await dictation.value
		try await pick.value
		#expect(log == ["old start", "old end", "new"])
	}

	@Test func concurrentDictationReloadsShareOneLoad() async throws {
		let queue = ModelOperationQueue()
		let network = Gate()
		let reload = Gate()
		var loads = 0

		let download = Task { try await queue.run { await network.wait() } }
		await yieldUntil { network.isWaiting }

		let first = Task {
			try await queue.restore(canRunBesideCurrent: { true }, isNeeded: { true }) {
				loads += 1
				await reload.wait()
			}
		}
		await yieldUntil { reload.isWaiting }
		let second = Task {
			try await queue.restore(canRunBesideCurrent: { true }, isNeeded: { true }) { loads += 1 }
		}
		for _ in 0..<20 { await Task.yield() }
		reload.open()
		try await first.value
		try await second.value
		network.open()
		try await download.value
		#expect(loads == 1)
	}
}
