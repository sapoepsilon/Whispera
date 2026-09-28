import Foundation

/// Runs `onChange` on the main thread when one of `keys` changes. Unlike
/// `UserDefaults.didChangeNotification`, which fires for every write to any key in the
/// process, this only wakes its owner for the settings it actually depends on.
final class DefaultsKeyObserver: NSObject {
	private let defaults: UserDefaults
	private let keys: [String]
	private let onChange: @MainActor () -> Void

	init(
		defaults: UserDefaults = .standard, keys: [String], onChange: @escaping @MainActor () -> Void
	) {
		self.defaults = defaults
		self.keys = keys
		self.onChange = onChange
		super.init()
		for key in keys {
			// KVO treats a dot as a key path separator, so such a key would never be observed
			assert(!key.contains("."), "UserDefaults key \(key) cannot be observed with KVO")
			defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
		}
	}

	deinit {
		for key in keys {
			defaults.removeObserver(self, forKeyPath: key, context: nil)
		}
	}

	override func observeValue(
		forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
		context: UnsafeMutableRawPointer?
	) {
		guard let keyPath, keys.contains(keyPath), (object as? UserDefaults) === defaults else {
			return
		}
		if Thread.isMainThread {
			MainActor.assumeIsolated { onChange() }
		} else {
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				MainActor.assumeIsolated { self.onChange() }
			}
		}
	}
}
