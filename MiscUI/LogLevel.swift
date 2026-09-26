import Foundation
import SwiftUI
import os.log

enum LogLevel: String, CaseIterable, Identifiable, Comparable {
	case error
	case info
	case debug

	static let defaultsKey = "logLevel"
	static let legacyDebugKey = "enableDebugLogging"

	var id: String { rawValue }

	var displayName: LocalizedStringKey {
		switch self {
		case .error: return "Errors only"
		case .info: return "Info"
		case .debug: return "Debug"
		}
	}

	private var rank: Int {
		switch self {
		case .error: return 0
		case .info: return 1
		case .debug: return 2
		}
	}

	static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
		lhs.rank < rhs.rank
	}

	static func severity(of type: OSLogType) -> LogLevel {
		switch type {
		case .error, .fault: return .error
		case .debug: return .debug
		default: return .info
		}
	}

	func allows(_ type: OSLogType) -> Bool {
		LogLevel.severity(of: type) <= self
	}

	static func stored(in defaults: UserDefaults = .standard) -> LogLevel {
		if let raw = defaults.string(forKey: defaultsKey), let level = LogLevel(rawValue: raw) {
			return level
		}
		return defaults.bool(forKey: legacyDebugKey) ? .debug : .info
	}

	// The legacy flag is kept in sync so builds that predate the picker keep the same verbosity.
	static func store(_ level: LogLevel, in defaults: UserDefaults = .standard) {
		defaults.set(level.rawValue, forKey: defaultsKey)
		defaults.set(level == .debug, forKey: legacyDebugKey)
	}
}

enum DebugMode {
	static let defaultsKey = "debugModeEnabled"

	static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
		defaults.bool(forKey: defaultsKey)
	}

	@discardableResult
	static func toggle(in defaults: UserDefaults = .standard) -> Bool {
		let enabled = !isEnabled(in: defaults)
		defaults.set(enabled, forKey: defaultsKey)
		AppLogger.shared.general.info("Debug mode \(enabled ? "enabled" : "disabled")")
		return enabled
	}
}
