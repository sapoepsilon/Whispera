import Foundation
import Testing

@testable import Whispera

/// A clock the test advances by hand: every sleep parks until `fire()` releases it.
@MainActor
final class ManualSleepClock {
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private(set) var requestedDelays: [TimeInterval] = []

	nonisolated var sleeper: DeferredAction.Sleeper {
		{ [self] delay in await self.park(delay) }
	}

	var pendingCount: Int { waiters.count }

	private func park(_ delay: TimeInterval) async {
		requestedDelays.append(delay)
		await withCheckedContinuation { waiters.append($0) }
	}

	func fire() {
		let released = waiters
		waiters = []
		released.forEach { $0.resume() }
	}

	func waitForSleepers(_ count: Int = 1) async {
		for _ in 0..<1000 where waiters.count < count {
			await Task.yield()
		}
	}
}

@MainActor
private final class StopCounter {
	var count = 0
}

@MainActor
private func settle() async {
	for _ in 0..<50 { await Task.yield() }
}

@MainActor
struct TailStopCoordinatorTests {
	private func makeTail(ms: Int) -> TimeInterval {
		let defaults = UserDefaults(suiteName: "TailStopCoordinatorTests.\(UUID().uuidString)")!
		defaults.set(ms, forKey: RecordingControlSettings.Key.extraRecordingBufferMs)
		return RecordingControlSettings(defaults: defaults).extraRecordingBuffer
	}

	@Test func zeroTailStopsImmediately() {
		let clock = ManualSleepClock()
		let coordinator = TailStopCoordinator(timer: DeferredAction(sleep: clock.sleeper))
		let stops = StopCounter()

		coordinator.requestStop(tail: makeTail(ms: 0)) { stops.count += 1 }

		#expect(stops.count == 1)
		#expect(!coordinator.isFinalizing)
	}

	@Test func tailDefersStopUntilTheTimerFires() async {
		let clock = ManualSleepClock()
		let coordinator = TailStopCoordinator(timer: DeferredAction(sleep: clock.sleeper))
		let stops = StopCounter()

		coordinator.requestStop(tail: makeTail(ms: 250)) { stops.count += 1 }
		await clock.waitForSleepers()

		#expect(coordinator.isFinalizing)
		#expect(clock.requestedDelays == [0.25])
		#expect(stops.count == 0)

		clock.fire()
		await settle()

		#expect(stops.count == 1)
		#expect(!coordinator.isFinalizing)
	}

	@Test func stopPressedAgainDuringTailIsIgnored() async {
		let clock = ManualSleepClock()
		let coordinator = TailStopCoordinator(timer: DeferredAction(sleep: clock.sleeper))
		let stops = StopCounter()

		#expect(coordinator.requestStop(tail: 0.2) { stops.count += 1 })
		await clock.waitForSleepers()
		#expect(!coordinator.requestStop(tail: 0.2) { stops.count += 1 })
		#expect(clock.pendingCount == 1)

		clock.fire()
		await settle()
		#expect(stops.count == 1)
	}

	@Test func cancelDuringTailDropsTheStop() async {
		let clock = ManualSleepClock()
		let coordinator = TailStopCoordinator(timer: DeferredAction(sleep: clock.sleeper))
		let stops = StopCounter()

		coordinator.requestStop(tail: 0.3) { stops.count += 1 }
		await clock.waitForSleepers()
		coordinator.cancel()
		#expect(!coordinator.isFinalizing)

		// The parked sleep ends after the cancel, as a real timer would; it must not stop anything
		clock.fire()
		await settle()
		#expect(stops.count == 0)
	}

	@Test func nextRecordingCanUseTheTailAfterACancel() async {
		let clock = ManualSleepClock()
		let coordinator = TailStopCoordinator(timer: DeferredAction(sleep: clock.sleeper))
		let cancelled = StopCounter()
		let stops = StopCounter()

		coordinator.requestStop(tail: 0.3) { cancelled.count += 1 }
		await clock.waitForSleepers()
		coordinator.cancel()

		#expect(coordinator.requestStop(tail: 0.3) { stops.count += 1 })
		await clock.waitForSleepers(2)
		clock.fire()
		await settle()

		#expect(cancelled.count == 0)
		#expect(stops.count == 1)
	}
}
