import Foundation
import Testing

@testable import Whispera

@MainActor
struct DefaultsKeyObserverTests {
	private final class Counter: @unchecked Sendable {
		var count = 0
		var calledOnMainThread = true
	}

	private func makeDefaults(_ name: String = #function) -> (UserDefaults, String) {
		let suite = "DefaultsKeyObserverTests.\(name).\(UUID().uuidString)"
		return (UserDefaults(suiteName: suite)!, suite)
	}

	@Test func firesOnlyForTheObservedKeys() {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		let counter = Counter()
		let observer = DefaultsKeyObserver(defaults: defaults, keys: ["watched", "alsoWatched"]) {
			counter.count += 1
		}

		defaults.set("x", forKey: "unrelated")
		defaults.set(1, forKey: "anotherUnrelated")
		#expect(counter.count == 0)

		defaults.set("a", forKey: "watched")
		#expect(counter.count == 1)
		defaults.set(true, forKey: "alsoWatched")
		#expect(counter.count == 2)
		defaults.removeObject(forKey: "watched")
		#expect(counter.count == 3)
		withExtendedLifetime(observer) {}
	}

	@Test func stopsObservingWhenReleased() {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		let counter = Counter()
		var observer: DefaultsKeyObserver? = DefaultsKeyObserver(defaults: defaults, keys: ["watched"]) {
			counter.count += 1
		}
		defaults.set(1, forKey: "watched")
		#expect(counter.count == 1)

		observer = nil
		defaults.set(2, forKey: "watched")
		#expect(counter.count == 1)
		#expect(observer == nil)
	}

	@Test func deliversBackgroundWritesOnTheMainThread() async throws {
		let (defaults, suite) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suite) }
		let counter = Counter()
		let observer = DefaultsKeyObserver(defaults: defaults, keys: ["watched"]) {
			counter.count += 1
			counter.calledOnMainThread = counter.calledOnMainThread && Thread.isMainThread
		}

		await Task.detached {
			defaults.set("from background", forKey: "watched")
		}.value
		let deadline = Date().addingTimeInterval(2)
		while counter.count == 0, Date() < deadline {
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		#expect(counter.count == 1)
		#expect(counter.calledOnMainThread)
		withExtendedLifetime(observer) {}
	}
}
