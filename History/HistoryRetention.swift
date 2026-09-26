import Foundation

enum HistoryRetentionPeriod: String, CaseIterable, Identifiable, Sendable {
	case never
	case preserveLimit
	case days3
	case weeks2
	case months3

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .never: return String(localized: "Keep forever")
		case .preserveLimit: return String(localized: "Keep the latest entries")
		case .days3: return String(localized: "3 days")
		case .weeks2: return String(localized: "2 weeks")
		case .months3: return String(localized: "3 months")
		}
	}

	var maxAge: TimeInterval? {
		let day: TimeInterval = 24 * 60 * 60
		switch self {
		case .never, .preserveLimit: return nil
		case .days3: return 3 * day
		case .weeks2: return 14 * day
		case .months3: return 90 * day
		}
	}
}

struct HistorySettings: Equatable, Sendable {
	static let enabledKey = "historyEnabled"
	static let saveAudioKey = "historySaveAudio"
	static let retentionKey = "historyRetentionPeriod"
	static let limitKey = "historyLimit"

	static let defaultEnabled = true
	static let defaultSaveAudio = true
	static let defaultRetention = HistoryRetentionPeriod.preserveLimit
	static let defaultLimit = 50
	static let limitRange = 1...10_000

	var isEnabled: Bool
	var savesAudio: Bool
	var retention: HistoryRetentionPeriod
	var limit: Int

	init(
		isEnabled: Bool = HistorySettings.defaultEnabled,
		savesAudio: Bool = HistorySettings.defaultSaveAudio,
		retention: HistoryRetentionPeriod = HistorySettings.defaultRetention,
		limit: Int = HistorySettings.defaultLimit
	) {
		self.isEnabled = isEnabled
		self.savesAudio = savesAudio
		self.retention = retention
		self.limit = limit
	}

	init(defaults: UserDefaults) {
		let storedLimit = defaults.object(forKey: Self.limitKey) as? Int ?? Self.defaultLimit
		self.init(
			isEnabled: defaults.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled,
			savesAudio: defaults.object(forKey: Self.saveAudioKey) as? Bool ?? Self.defaultSaveAudio,
			retention: defaults.string(forKey: Self.retentionKey)
				.flatMap(HistoryRetentionPeriod.init(rawValue:)) ?? Self.defaultRetention,
			limit: min(max(storedLimit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
		)
	}

	func save(to defaults: UserDefaults) {
		defaults.set(isEnabled, forKey: Self.enabledKey)
		defaults.set(savesAudio, forKey: Self.saveAudioKey)
		defaults.set(retention.rawValue, forKey: Self.retentionKey)
		defaults.set(limit, forKey: Self.limitKey)
	}
}

struct HistoryRetentionCandidate: Sendable {
	let id: UUID
	let createdAt: Date
	let isStarred: Bool
}

enum HistoryRetention {
	/// Starred entries are never removed and do not count toward the entry limit.
	static func idsToDelete(
		from candidates: [HistoryRetentionCandidate],
		period: HistoryRetentionPeriod,
		limit: Int,
		now: Date
	) -> Set<UUID> {
		let unstarred = candidates.filter { !$0.isStarred }

		switch period {
		case .never:
			return []
		case .preserveLimit:
			let keep = max(limit, 0)
			let newestFirst = unstarred.sorted { $0.createdAt > $1.createdAt }
			return Set(newestFirst.dropFirst(keep).map(\.id))
		case .days3, .weeks2, .months3:
			guard let maxAge = period.maxAge else { return [] }
			let cutoff = now.addingTimeInterval(-maxAge)
			return Set(unstarred.filter { $0.createdAt < cutoff }.map(\.id))
		}
	}
}
