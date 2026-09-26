import Foundation
import Observation

/// A Bool setting that SwiftUI can observe through an `@Observable` owner. `@AppStorage` inside an
/// `@Observable` class has to be `@ObservationIgnored`, so views reading it never refresh when
/// Settings, a shortcut or a remote command changes the value. This mirrors the key with KVO instead.
@MainActor
@Observable
final class ObservedDefaultsFlag {
	private(set) var value: Bool

	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private let key: String
	@ObservationIgnored private let defaultValue: Bool
	@ObservationIgnored private var observer: DefaultsKeyObserver?

	init(key: String, defaultValue: Bool, defaults: UserDefaults = .standard) {
		self.key = key
		self.defaultValue = defaultValue
		self.defaults = defaults
		value = Self.read(key: key, defaultValue: defaultValue, from: defaults)
		observer = DefaultsKeyObserver(defaults: defaults, keys: [key]) { [weak self] in
			self?.refresh()
		}
	}

	func set(_ newValue: Bool) {
		if value != newValue { value = newValue }
		defaults.set(newValue, forKey: key)
	}

	private func refresh() {
		let stored = Self.read(key: key, defaultValue: defaultValue, from: defaults)
		if value != stored { value = stored }
	}

	private static func read(key: String, defaultValue: Bool, from defaults: UserDefaults) -> Bool {
		defaults.object(forKey: key) as? Bool ?? defaultValue
	}
}
