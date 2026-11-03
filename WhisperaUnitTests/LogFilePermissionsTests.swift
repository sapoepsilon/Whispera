import Foundation
import Testing

@testable import Whispera

struct LogFilePermissionsTests {
	private func makeDirectory() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("LogFilePermissionsTests-\(UUID().uuidString)", isDirectory: true)
	}

	private func permissions(_ url: URL) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
	}

	@Test func newLogFileIsOwnerOnly() throws {
		let directory = makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try LogFileWriter.secureLogsDirectory(directory)
		let url = directory.appendingPathComponent("whispera-test.log")
		let writer = LogFileWriter()

		#expect(writer.append(Data("line\n".utf8), to: url))
		writer.close()

		#expect(try permissions(url) == 0o600)
		#expect(try permissions(directory) == 0o700)
	}

	@Test func existingWorldReadableLogIsTightenedWhenOpened() throws {
		let directory = makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent("whispera-old.log")
		#expect(
			FileManager.default.createFile(
				atPath: url.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644]))
		let writer = LogFileWriter()

		#expect(writer.append(Data("new\n".utf8), to: url))
		writer.close()

		#expect(try permissions(url) == 0o600)
		#expect(try String(contentsOf: url, encoding: .utf8) == "old\nnew\n")
	}

	@Test func securingTheFolderTightensItAndEveryLogAlreadyInIt() throws {
		let directory = makeDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
		let current = directory.appendingPathComponent("whispera-1-1-26.log")
		let archived = directory.appendingPathComponent("whispera-1-1-26-1700000000.log")
		let other = directory.appendingPathComponent("notes.txt")
		for file in [current, archived, other] {
			FileManager.default.createFile(
				atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o644])
		}

		try LogFileWriter.secureLogsDirectory(directory)

		#expect(try permissions(directory) == 0o700)
		#expect(try permissions(current) == 0o600)
		#expect(try permissions(archived) == 0o600)
		#expect(try permissions(other) == 0o644)
	}
}
