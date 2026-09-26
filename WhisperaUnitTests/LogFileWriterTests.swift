import Foundation
import Testing

@testable import Whispera

struct LogFileWriterTests {
	private final class Clock {
		var now = Date(timeIntervalSince1970: 1_000_000)
	}

	private func makeLogURL() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LogFileWriterTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory.appendingPathComponent("test.log")
	}

	private func line(_ text: String) -> Data { Data("\(text)\n".utf8) }

	@Test func appendsLinesToANewFile() throws {
		let url = try makeLogURL()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let writer = LogFileWriter()

		#expect(writer.append(line("one"), to: url))
		#expect(writer.append(line("two"), to: url))
		writer.close()

		#expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
	}

	/// A handle that cannot be written to stands in for a full disk: the legacy
	/// `FileHandle.write(_:)` raises an Objective-C exception here and would abort the process.
	@Test func failedWriteIsDroppedAndBacksOffInsteadOfCrashing() throws {
		let url = try makeLogURL()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let clock = Clock()
		var opens = 0
		var failing = true
		let writer = LogFileWriter(backoff: 30, now: { clock.now }) { url in
			opens += 1
			return failing ? try FileHandle(forReadingFrom: url) : try FileHandle(forWritingTo: url)
		}

		#expect(!writer.append(line("lost"), to: url))
		#expect(opens == 1)
		#expect(writer.suspendedUntil == clock.now.addingTimeInterval(30))

		clock.now.addTimeInterval(10)
		#expect(!writer.append(line("also lost"), to: url))
		#expect(opens == 1, "Writes during the backoff must not touch the disk")
		#expect(writer.droppedLines == 2)

		failing = false
		clock.now.addTimeInterval(25)
		#expect(writer.append(line("back"), to: url))
		#expect(opens == 2)
		#expect(writer.suspendedUntil == nil)
		#expect(writer.droppedLines == 0)
		writer.close()

		let contents = try String(contentsOf: url, encoding: .utf8)
		#expect(contents.hasPrefix("back\n"))
		#expect(contents.contains("2 line(s) were dropped"))
		#expect(!contents.contains("lost"))
	}

	@Test func unopenableFileIsDroppedQuietly() throws {
		let url = try makeLogURL()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		// A directory in the log file's place cannot be opened for writing
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		let writer = LogFileWriter()

		#expect(!writer.append(line("x"), to: url))
		#expect(writer.suspendedUntil != nil)
	}

	@Test func switchingFilesReopensTheHandle() throws {
		let first = try makeLogURL()
		let second = first.deletingLastPathComponent().appendingPathComponent("next.log")
		defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
		let writer = LogFileWriter()

		#expect(writer.append(line("a"), to: first))
		#expect(writer.append(line("b"), to: second))
		writer.close()

		#expect(try String(contentsOf: first, encoding: .utf8) == "a\n")
		#expect(try String(contentsOf: second, encoding: .utf8) == "b\n")
	}
}
