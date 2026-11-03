import Foundation

/// The append-only `key=value` ops and audit log (PROTOCOL §14), byte-compatible with the
/// Python daemon's so the broker's and the helper's logs read the same way.
///
/// Callers MUST NOT pass secrets, prompt text, audio, transcripts or signatures.
public final class OpsLog: @unchecked Sendable {
	public let path: String?
	public let debugEnabled: Bool
	private let lock = NSLock()
	private static let fieldOrder = ["ts", "evt", "device", "route", "status", "ms", "request_id", "detail"]
	private static let timestamp: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
		return formatter
	}()

	public init(path: String?, debug: Bool = false) {
		self.path = path
		self.debugEnabled = debug
		if let path {
			try? FileManager.default.createDirectory(
				atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
		}
	}

	public static let null = OpsLog(path: nil)

	public func callAsFunction(_ event: String, _ fields: [String: Any?] = [:]) {
		log(event, fields)
	}

	public func debug(_ event: String, _ fields: [String: Any?] = [:]) {
		if debugEnabled { log(event, fields) }
	}

	public func log(_ event: String, _ fields: [String: Any?] = [:]) {
		guard let path else { return }
		var values: [String: String] = [:]
		for (key, value) in fields {
			guard let value else { continue }
			values[key] = "\(value)"
		}
		values["evt"] = event
		if values["ts"] == nil {
			lock.lock()
			values["ts"] = Self.timestamp.string(from: Date())
			lock.unlock()
		}
		let ordered =
			Self.fieldOrder.filter { values[$0] != nil }
			+ values.keys.filter { !Self.fieldOrder.contains($0) }.sorted()
		let line =
			ordered.map { key -> String in
				var value = Self.clean(values[key] ?? "", 200)
				if value.isEmpty || value.contains(" ") || value.contains("\"") {
					value = "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
				}
				return "\(key)=\(value)"
			}.joined(separator: " ") + "\n"
		lock.lock()
		defer { lock.unlock() }
		let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
		guard fd >= 0 else { return }
		defer { close(fd) }
		_ = line.utf8CString.withUnsafeBufferPointer { buffer in
			write(fd, buffer.baseAddress, buffer.count - 1)
		}
	}

	/// Same rule as bws-touchid `clean()`: printable characters only, capped length.
	public static func clean(_ text: String, _ limit: Int = 80) -> String {
		let printable = String(
			String.UnicodeScalarView(
				text.unicodeScalars.filter { scalar in
					!CharacterSet.controlCharacters.contains(scalar)
						&& !CharacterSet.illegalCharacters.contains(scalar)
						&& (scalar == " " || !CharacterSet.whitespacesAndNewlines.contains(scalar))
				}))
		guard printable.count > limit else { return printable }
		return String(printable.prefix(limit)) + "…"
	}
}
