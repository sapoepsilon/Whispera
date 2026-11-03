import Foundation

/// What one phone wants pushed (contract §4): per-event toggles, muted agents and quiet hours.
/// Set with `PUT /v1/notifications/prefs`, stored per device id.
public struct NotificationPrefs: Equatable, Sendable {
	public struct QuietHours: Equatable, Sendable {
		/// Minutes after local midnight in `tz`; `start > end` wraps midnight.
		public var start: Int
		public var end: Int
		public var tz: String
		/// Permission prompts and asks still go during quiet hours.
		public var allowPermission: Bool

		/// Whether `date` falls inside the window (start inclusive, end exclusive). An empty
		/// window (`start == end`) is never quiet.
		public func contains(_ date: Date) -> Bool {
			guard start != end, let zone = TimeZone(identifier: tz) else { return false }
			var calendar = Calendar(identifier: .gregorian)
			calendar.timeZone = zone
			let parts = calendar.dateComponents([.hour, .minute], from: date)
			let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
			return start < end ? (start <= minute && minute < end) : (minute >= start || minute < end)
		}
	}

	public static let eventKeys = ["permission", "ask", "turn_done", "subagents_done", "stopped"]
	/// Events about an agent's progress: muting an agent silences these, not its dialogs.
	public static let agentEvents: Set<String> = ["turn_done", "subagents_done", "stopped"]
	public static let dialogEvents: Set<String> = ["permission", "ask"]
	public static let maxMutedAgents = 200
	public static let maxAgentIDLength = 256

	public var events: [String: Bool]
	public var mutedAgents: [String]
	public var quietHours: QuietHours?

	public init(events: [String: Bool] = [:], mutedAgents: [String] = [], quietHours: QuietHours? = nil) {
		var all = Dictionary(uniqueKeysWithValues: Self.eventKeys.map { ($0, true) })
		for (key, value) in events where all[key] != nil { all[key] = value }
		self.events = all
		self.mutedAgents = mutedAgents
		self.quietHours = quietHours
	}

	public static let defaults = NotificationPrefs()

	/// Whether `event` about `agentID` may be pushed to this phone at `date`.
	public func allows(_ event: String, agentID: String?, at date: Date) -> Bool {
		guard events[event] ?? true else { return false }
		if Self.agentEvents.contains(event), let agentID, mutedAgents.contains(agentID) { return false }
		if let quietHours, quietHours.contains(date) {
			return quietHours.allowPermission && Self.dialogEvents.contains(event)
		}
		return true
	}

	public var json: [String: Any] {
		var body: [String: Any] = [
			"events": events, "muted_agents": mutedAgents, "quiet_hours": NSNull(),
		]
		if let quietHours {
			body["quiet_hours"] = [
				"start": quietHours.start, "end": quietHours.end, "tz": quietHours.tz,
				"allow_permission": quietHours.allowPermission,
			]
		}
		return body
	}

	/// A `PUT` body, strictly: unknown keys, wrong types and oversized lists are 400s. Keys
	/// left out keep their defaults (every event on, nobody muted, no quiet hours).
	public static func parse(_ body: [String: Any]) throws -> NotificationPrefs {
		func bad(_ message: String) -> APIError { APIError(400, "bad_request", message) }
		let unknown = Set(body.keys).subtracting(["events", "muted_agents", "quiet_hours"])
		guard unknown.isEmpty else { throw bad("unknown key \(unknown.sorted().first!.prefix(40))") }
		var events: [String: Bool] = [:]
		if let raw = body["events"], !(raw is NSNull) {
			guard let object = raw as? [String: Any] else { throw bad("events must be an object") }
			for (key, value) in object {
				guard eventKeys.contains(key) else { throw bad("unknown event \(key.prefix(40))") }
				guard let flag = strictBool(value) else { throw bad("events.\(key) must be a boolean") }
				events[key] = flag
			}
		}
		var muted: [String] = []
		if let raw = body["muted_agents"], !(raw is NSNull) {
			guard let list = raw as? [Any] else { throw bad("muted_agents must be a list of agent ids") }
			guard list.count <= maxMutedAgents else { throw bad("muted_agents is limited to \(maxMutedAgents)") }
			for item in list {
				guard let id = item as? String, !id.isEmpty, id.count <= maxAgentIDLength else {
					throw bad("muted_agents must hold agent ids of 1-\(maxAgentIDLength) characters")
				}
				if !muted.contains(id) { muted.append(id) }
			}
		}
		var quiet: QuietHours?
		if let raw = body["quiet_hours"], !(raw is NSNull) {
			guard let object = raw as? [String: Any] else { throw bad("quiet_hours must be an object or null") }
			let unknown = Set(object.keys).subtracting(["start", "end", "tz", "allow_permission"])
			guard unknown.isEmpty else { throw bad("unknown quiet_hours key \(unknown.sorted().first!.prefix(40))") }
			guard let start = WireJSON.strictInt(object["start"]), (0..<1440).contains(start),
				let end = WireJSON.strictInt(object["end"]), (0..<1440).contains(end)
			else { throw bad("quiet_hours start and end must be minutes 0-1439") }
			guard let tz = object["tz"] as? String, tz.count <= 64, TimeZone(identifier: tz) != nil else {
				throw bad("quiet_hours.tz must be an IANA time zone")
			}
			var allow = true
			if let value = object["allow_permission"], !(value is NSNull) {
				guard let flag = strictBool(value) else { throw bad("quiet_hours.allow_permission must be a boolean") }
				allow = flag
			}
			quiet = QuietHours(start: start, end: end, tz: tz, allowPermission: allow)
		}
		return NotificationPrefs(events: events, mutedAgents: muted, quietHours: quiet)
	}

	/// A JSON boolean, not a number.
	static func strictBool(_ value: Any?) -> Bool? {
		guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
		return number.boolValue
	}

	init?(stored: [String: Any]) {
		guard let parsed = try? Self.parse(stored) else { return nil }
		self = parsed
	}
}

/// Every phone's prefs, in `notification-prefs.json` in the helper's state directory.
public final class NotificationPrefsStore: @unchecked Sendable {
	private let path: String
	private let now: () -> Date
	private let lock = NSLock()
	private var byDevice: [String: NotificationPrefs] = [:]

	public init(path: String, now: @escaping () -> Date = { Date() }) {
		self.path = path
		self.now = now
		if let object = (try? FileStore.readJSON(path)) as? [String: Any],
			let devices = object["devices"] as? [String: Any]
		{
			for (id, value) in devices {
				if let stored = value as? [String: Any], let prefs = NotificationPrefs(stored: stored) {
					byDevice[id] = prefs
				}
			}
		}
	}

	public func prefs(_ deviceID: String) -> NotificationPrefs {
		lock.lock()
		defer { lock.unlock() }
		return byDevice[deviceID] ?? .defaults
	}

	public func set(_ prefs: NotificationPrefs, for deviceID: String) throws {
		lock.lock()
		defer { lock.unlock() }
		var next = byDevice
		next[deviceID] = prefs
		try FileStore.writeJSONAtomic(["devices": next.mapValues(\.json)], to: path)
		byDevice = next
	}

	/// Whether `deviceID` wants `event` about `agentID` now.
	public func allows(_ deviceID: String, _ event: String, agentID: String?) -> Bool {
		prefs(deviceID).allows(event, agentID: agentID, at: now())
	}
}
