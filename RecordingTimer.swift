import Foundation

@MainActor
@Observable
final class RecordingTimer {
	private(set) var duration: TimeInterval = 0
	private(set) var isRunning = false

	@ObservationIgnored
	private var timerTask: Task<Void, Never>?

	var formatted: String {
		let minutes = Int(duration) / 60
		let seconds = Int(duration) % 60
		let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
		return String(format: "%02d:%02d.%01d", minutes, seconds, tenths)
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		duration = 0

		timerTask = Task {
			let start = ContinuousClock.now
			for await _ in timerStream() {
				guard !Task.isCancelled else { break }
				duration = (ContinuousClock.now - start).seconds
			}
		}
	}

	func stop() {
		isRunning = false
		timerTask?.cancel()
		timerTask = nil
	}

	func reset() {
		stop()
		duration = 0
	}
}

extension RecordingTimer {
	fileprivate func timerStream() -> AsyncStream<Void> {
		AsyncStream { continuation in
			let timer = DispatchSource.makeTimerSource(queue: .main)
			timer.schedule(deadline: .now(), repeating: .milliseconds(100))
			timer.setEventHandler { continuation.yield() }

			continuation.onTermination = { _ in timer.cancel() }
			timer.resume()
		}
	}
}

extension Duration {
	fileprivate var seconds: TimeInterval {
		Double(components.seconds) + Double(components.attoseconds) / 1e18
	}
}
