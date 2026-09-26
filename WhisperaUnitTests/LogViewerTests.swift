import Foundation
import Testing
import os.log

@testable import Whispera

struct LogLevelTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "LogLevelTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsToInfo() {
		#expect(LogLevel.stored(in: isolatedDefaults()) == .info)
	}

	@Test func migratesLegacyDebugFlag() {
		let defaults = isolatedDefaults()
		defaults.set(true, forKey: LogLevel.legacyDebugKey)
		#expect(LogLevel.stored(in: defaults) == .debug)
	}

	@Test(arguments: LogLevel.allCases)
	func storeRoundTripsAndSyncsLegacyFlag(level: LogLevel) {
		let defaults = isolatedDefaults()
		LogLevel.store(level, in: defaults)
		#expect(LogLevel.stored(in: defaults) == level)
		#expect(defaults.bool(forKey: LogLevel.legacyDebugKey) == (level == .debug))
	}

	@Test func errorLevelOnlyAllowsErrorsAndFaults() {
		#expect(LogLevel.error.allows(.error))
		#expect(LogLevel.error.allows(.fault))
		#expect(!LogLevel.error.allows(.info))
		#expect(!LogLevel.error.allows(.default))
		#expect(!LogLevel.error.allows(.debug))
	}

	@Test func infoLevelDropsDebugOnly() {
		#expect(LogLevel.info.allows(.info))
		#expect(LogLevel.info.allows(.default))
		#expect(LogLevel.info.allows(.error))
		#expect(!LogLevel.info.allows(.debug))
	}

	@Test func debugLevelAllowsEverything() {
		for type in [OSLogType.debug, .info, .default, .error, .fault] {
			#expect(LogLevel.debug.allows(type))
		}
	}

	@Test func debugModeToggles() {
		let defaults = isolatedDefaults()
		#expect(!DebugMode.isEnabled(in: defaults))
		#expect(DebugMode.toggle(in: defaults))
		#expect(DebugMode.isEnabled(in: defaults))
		#expect(!DebugMode.toggle(in: defaults))
	}
}

struct LogEntryTests {

	@Test func parsesLogManagerFormat() {
		let entry = LogEntry.parse(
			"[2026-09-25 10:00:00.000] [ERROR] [AudioManager] Engine failed [code 5]", id: 7)
		#expect(entry.id == 7)
		#expect(entry.level == .error)
		#expect(entry.category == "AudioManager")
	}

	@Test func mapsLevels() {
		#expect(LogEntry.parse("[t] [FAULT] [UI] x", id: 0).level == .error)
		#expect(LogEntry.parse("[t] [DEBUG] [UI] x", id: 0).level == .debug)
		#expect(LogEntry.parse("[t] [INFO] [UI] x", id: 0).level == .info)
		#expect(LogEntry.parse("[t] [DEFAULT] [UI] x", id: 0).level == .info)
	}

	@Test func keepsUnstructuredLinesVerbatim() {
		let entry = LogEntry.parse("Call Stack:", id: 1)
		#expect(entry.level == .info)
		#expect(entry.category.isEmpty)
		#expect(entry.raw == "Call Stack:")
	}

	@Test func filtersByLevelAndQuery() {
		let debug = LogEntry.parse("[t] [DEBUG] [UI] tapped button", id: 0)
		let error = LogEntry.parse("[t] [ERROR] [Network] timeout", id: 1)
		#expect(!debug.matches(minimum: .info, query: ""))
		#expect(debug.matches(minimum: .debug, query: "BUTTON"))
		#expect(error.matches(minimum: .error, query: ""))
		#expect(!error.matches(minimum: .debug, query: "button"))
	}
}

@MainActor
struct LogTailerTests {

	private func makeTempFile() throws -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("LogTailerTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("whispera.log")
	}

	private func append(_ text: String, to url: URL) throws {
		if !FileManager.default.fileExists(atPath: url.path) {
			FileManager.default.createFile(atPath: url.path, contents: nil)
		}
		let handle = try FileHandle(forWritingTo: url)
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
		try handle.close()
	}

	@Test func readsExistingAndAppendedLines() throws {
		let url = try makeTempFile()
		try append("[t] [INFO] [UI] one\n[t] [ERROR] [UI] two\n", to: url)
		let tailer = LogTailer(fileProvider: { url })

		tailer.poll()
		#expect(tailer.entries.map(\.raw) == ["[t] [INFO] [UI] one", "[t] [ERROR] [UI] two"])

		try append("[t] [DEBUG] [UI] three\n", to: url)
		tailer.poll()
		#expect(tailer.entries.count == 3)
		#expect(tailer.entries.last?.level == .debug)
	}

	@Test func holdsPartialLinesUntilTheNewlineArrives() throws {
		let url = try makeTempFile()
		try append("[t] [INFO] [UI] hal", to: url)
		let tailer = LogTailer(fileProvider: { url })
		tailer.poll()
		#expect(tailer.entries.isEmpty)

		try append("f\n", to: url)
		tailer.poll()
		#expect(tailer.entries.map(\.raw) == ["[t] [INFO] [UI] half"])
	}

	@Test func restartsAfterTruncation() throws {
		let url = try makeTempFile()
		try append("[t] [INFO] [UI] old line that is long\n", to: url)
		let tailer = LogTailer(fileProvider: { url })
		tailer.poll()

		try Data("[t] [INFO] [UI] new\n".utf8).write(to: url)
		tailer.poll()
		#expect(tailer.entries.map(\.raw) == ["[t] [INFO] [UI] new"])
	}

	@Test func capsEntryCount() throws {
		let url = try makeTempFile()
		try append((0..<10).map { "[t] [INFO] [UI] \($0)\n" }.joined(), to: url)
		let tailer = LogTailer(maxEntries: 4, fileProvider: { url })
		tailer.poll()
		#expect(tailer.entries.map(\.raw).last == "[t] [INFO] [UI] 9")
		#expect(tailer.entries.count == 4)
	}

	@Test func initialReadIsBoundedToTheFileTail() throws {
		let url = try makeTempFile()
		try append((0..<100).map { "[t] [INFO] [UI] line \($0)\n" }.joined(), to: url)
		let tailer = LogTailer(initialReadBytes: 60, fileProvider: { url })
		tailer.poll()
		#expect(tailer.entries.last?.raw == "[t] [INFO] [UI] line 99")
		#expect(tailer.entries.count == 2)
		#expect(tailer.entries.first?.raw == "[t] [INFO] [UI] line 98")
	}

	@Test func switchesToANewFile() throws {
		let first = try makeTempFile()
		let second = try makeTempFile()
		try append("[t] [INFO] [UI] first\n", to: first)
		try append("[t] [INFO] [UI] second\n", to: second)
		var current = first
		let tailer = LogTailer(fileProvider: { current })
		tailer.poll()
		current = second
		tailer.poll()
		#expect(tailer.entries.map(\.raw) == ["[t] [INFO] [UI] second"])
		#expect(tailer.fileURL == second)
	}
}
