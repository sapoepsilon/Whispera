import Foundation
import Testing

@testable import Whispera

// MARK: - Timestamp formatting (pure logic)

@MainActor
struct TimestampFormattingTests {

	private func makeSegments() -> [TranscriptionSegment] {
		[
			TranscriptionSegment(text: "Hello world.", startTime: 0.0, endTime: 2.4),
			TranscriptionSegment(text: "Second segment.", startTime: 65.2, endTime: 68.9),
			TranscriptionSegment(text: "One hour in.", startTime: 3661.0, endTime: 3665.0),
		]
	}

	@Test func formatsMinutesSeconds() {
		let manager = FileTranscriptionManager()
		let output = manager.formatSegmentsAsString(makeSegments(), format: "MM:SS")
		let lines = output.components(separatedBy: "\n")

		#expect(lines[0] == "[00:00] Hello world.")
		#expect(lines[1] == "[01:05] Second segment.")
		#expect(lines[2] == "[01:01] One hour in.")
	}

	@Test func formatsHoursMinutesSeconds() {
		let manager = FileTranscriptionManager()
		let output = manager.formatSegmentsAsString(makeSegments(), format: "HH:MM:SS")
		let lines = output.components(separatedBy: "\n")

		#expect(lines[0] == "[00:00:00] Hello world.")
		#expect(lines[1] == "[00:01:05] Second segment.")
		#expect(lines[2] == "[01:01:01] One hour in.")
	}

	@Test func formatsRawSeconds() {
		let manager = FileTranscriptionManager()
		let output = manager.formatSegmentsAsString(makeSegments(), format: "Seconds")

		#expect(output.hasPrefix("[0.0s] Hello world."))
		#expect(output.contains("[65.2s] Second segment."))
	}

	@Test func everyLineCarriesATimestampPrefix() {
		let manager = FileTranscriptionManager()
		let output = manager.formatSegmentsAsString(makeSegments(), format: "MM:SS")

		for line in output.components(separatedBy: "\n") {
			#expect(line.range(of: #"^\[\d{2}:\d{2}\] "#, options: .regularExpression) != nil)
		}
	}
}

// MARK: - Default resolution

struct TimestampDefaultResolutionTests {

	private func isolatedDefaults(_ name: String) -> UserDefaults {
		let suite = "TimestampDefaultResolutionTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func timestampsAreOnByDefaultWhenNothingWasEverSet() {
		let defaults = isolatedDefaults("untouched")
		#expect(FileTranscriptionManager.resolveIncludeTimestamps(from: defaults) == true)
	}

	@Test func plainModeDisablesTimestamps() {
		let defaults = isolatedDefaults("plain")
		defaults.set("plain", forKey: "defaultTranscriptionMode")
		#expect(FileTranscriptionManager.resolveIncludeTimestamps(from: defaults) == false)
	}

	@Test func explicitToggleOffDisablesTimestamps() {
		let defaults = isolatedDefaults("toggledOff")
		defaults.set("timestamps", forKey: "defaultTranscriptionMode")
		defaults.set(false, forKey: "showTimestamps")
		#expect(FileTranscriptionManager.resolveIncludeTimestamps(from: defaults) == false)
	}

	@Test func timestampsModeWithToggleOnEnablesTimestamps() {
		let defaults = isolatedDefaults("bothOn")
		defaults.set("timestamps", forKey: "defaultTranscriptionMode")
		defaults.set(true, forKey: "showTimestamps")
		#expect(FileTranscriptionManager.resolveIncludeTimestamps(from: defaults) == true)
	}

	@Test func registeredDefaultsEnableTimestampsOnFreshInstall() {
		let defaults = isolatedDefaults("registered")
		AppDelegate.registerInitialDefaults(in: defaults)
		#expect(FileTranscriptionManager.resolveIncludeTimestamps(from: defaults) == true)
		#expect(defaults.string(forKey: "timestampFormat") == "MM:SS")
	}
}

// MARK: - End-to-end (real WhisperKit)

// Renders a known phrase to an audio file with the system voice, transcribes it
// through the real file-transcription pipeline, and asserts the timestamped and
// plain outputs. Requires a downloaded Whisper model on the test machine.
@MainActor
struct FileTranscriptionTimestampE2ETests {

	private func synthesizeFixture() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("timestamp-e2e-\(UUID().uuidString).aiff")
		let say = Process()
		say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
		say.arguments = ["-o", url.path, "The quick brown fox jumps over the lazy dog"]
		try say.run()
		say.waitUntilExit()
		try #require(say.terminationStatus == 0)
		try #require(FileManager.default.fileExists(atPath: url.path))
		return url
	}

	@Test(.timeLimit(.minutes(10)))
	func timestampedTranscriptionCarriesTimestampsInEveryLine() async throws {
		let fixture = try synthesizeFixture()
		defer { try? FileManager.default.removeItem(at: fixture) }

		let manager = FileTranscriptionManager()
		let output = try await manager.transcribeFile(
			at: fixture, withTimestamps: true, timestampFormat: "MM:SS")

		try #require(!output.isEmpty)
		#expect(output.lowercased().contains("fox"))

		let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
		try #require(!lines.isEmpty)
		for line in lines {
			#expect(
				line.range(of: #"^\[\d{2}:\d{2}\] "#, options: .regularExpression) != nil,
				"line missing timestamp prefix: \(line)")
		}
	}

	@Test(.timeLimit(.minutes(10)))
	func plainTranscriptionCarriesNoTimestamps() async throws {
		let fixture = try synthesizeFixture()
		defer { try? FileManager.default.removeItem(at: fixture) }

		let manager = FileTranscriptionManager()
		let output = try await manager.transcribeFile(at: fixture, withTimestamps: false)

		try #require(!output.isEmpty)
		#expect(output.lowercased().contains("fox"))
		#expect(output.range(of: #"\[\d{2}:\d{2}\]"#, options: .regularExpression) == nil)
	}

	@Test(.timeLimit(.minutes(10)))
	func queuePathProducesTimestampsWithFreshDefaults() async throws {
		let fixture = try synthesizeFixture()
		defer { try? FileManager.default.removeItem(at: fixture) }

		// The exact resolution the queue path uses, against a fresh suite that has
		// only the registered defaults - the shipped first-launch configuration.
		let suite = "FileTranscriptionTimestampE2ETests.queue.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		AppDelegate.registerInitialDefaults(in: defaults)
		let includeTimestamps = FileTranscriptionManager.resolveIncludeTimestamps(from: defaults)
		try #require(includeTimestamps)

		let manager = FileTranscriptionManager()
		let output = try await manager.transcribeFile(
			at: fixture,
			withTimestamps: includeTimestamps,
			timestampFormat: defaults.string(forKey: "timestampFormat"))

		#expect(output.range(of: #"^\[\d{2}:\d{2}\] "#, options: .regularExpression) != nil)
		#expect(output.lowercased().contains("fox"))
	}
}
