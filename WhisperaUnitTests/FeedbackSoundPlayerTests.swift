import AppKit
import Foundation
import Testing

@testable import Whispera

@MainActor
struct FeedbackSoundPlayerTests {
	private func makeDefaults(_ name: String) throws -> (UserDefaults, String) {
		let suite = "FeedbackSoundPlayerTests.\(name).\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defaults.set(true, forKey: FeedbackSoundSettings.enabledKey)
		return (defaults, suite)
	}

	@Test func defaultsPlaySystemSoundsAtFullVolume() throws {
		let (defaults, suite) = try makeDefaults("defaults")
		defer { defaults.removePersistentDomain(forName: suite) }
		let settings = FeedbackSoundSettings(defaults: defaults)

		#expect(settings.volume == 1)
		#expect(settings.outputDeviceUID == FeedbackSoundSettings.systemOutputUID)
		#expect(settings.source(start: true) == .system("Tink"))
		#expect(settings.source(start: false) == .system("Pop"))
	}

	@Test func disabledFeedbackPlaysNothing() throws {
		let (defaults, suite) = try makeDefaults("disabled")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(false, forKey: FeedbackSoundSettings.enabledKey)

		#expect(FeedbackSoundSettings(defaults: defaults).source(start: true) == nil)
		#expect(FeedbackSoundPlayer.shared.play(start: true, defaults: defaults) == 0)
	}

	@Test func zeroVolumePlaysNothing() throws {
		let (defaults, suite) = try makeDefaults("mute")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(0.0, forKey: FeedbackSoundSettings.volumeKey)

		#expect(FeedbackSoundSettings(defaults: defaults).source(start: true) == nil)
	}

	@Test func volumeIsClamped() throws {
		let (defaults, suite) = try makeDefaults("clamp")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(3.5, forKey: FeedbackSoundSettings.volumeKey)
		#expect(FeedbackSoundSettings(defaults: defaults).volume == 1)
		defaults.set(-1.0, forKey: FeedbackSoundSettings.volumeKey)
		#expect(FeedbackSoundSettings(defaults: defaults).volume == 0)
	}

	@Test func noneSoundPlaysNothing() throws {
		let (defaults, suite) = try makeDefaults("none")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(FeedbackSoundSettings.noneSoundName, forKey: FeedbackSoundSettings.stopSoundKey)

		#expect(FeedbackSoundSettings(defaults: defaults).source(start: false) == nil)
	}

	@Test func customSoundUsesImportedFile() throws {
		let (defaults, suite) = try makeDefaults("custom")
		defer { defaults.removePersistentDomain(forName: suite) }
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }

		let systemSound = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
		let imported = try FeedbackSoundPlayer.importCustomSound(from: systemSound, start: true, directory: folder)
		#expect(FileManager.default.fileExists(atPath: imported.path))
		#expect(imported.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

		defaults.set(FeedbackSoundSettings.customSoundName, forKey: FeedbackSoundSettings.startSoundKey)
		defaults.set(imported.path, forKey: FeedbackSoundSettings.customStartPathKey)
		#expect(FeedbackSoundSettings(defaults: defaults).source(start: true) == .file(imported))
		#expect(FeedbackSoundPlayer.shared.duration(start: true, defaults: defaults) > 0)
	}

	@Test func customSoundWithMissingFilePlaysNothing() throws {
		let (defaults, suite) = try makeDefaults("missing")
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(FeedbackSoundSettings.customSoundName, forKey: FeedbackSoundSettings.stopSoundKey)
		defaults.set("/nonexistent/whispera-stop.aiff", forKey: FeedbackSoundSettings.customStopPathKey)

		#expect(FeedbackSoundSettings(defaults: defaults).source(start: false) == nil)
	}

	@Test func importRejectsFilesThatAreNotAudio() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let text = folder.appendingPathComponent("notes.txt")
		try Data("hello".utf8).write(to: text)

		#expect(throws: (any Error).self) {
			try FeedbackSoundPlayer.importCustomSound(
				from: text, start: false, directory: folder.appendingPathComponent("Sounds"))
		}
		let leftovers = try? FileManager.default.contentsOfDirectory(
			atPath: folder.appendingPathComponent("Sounds").path)
		#expect(leftovers?.isEmpty ?? true)
	}

	@Test func systemSoundDurationIsKnown() throws {
		let (defaults, suite) = try makeDefaults("duration")
		defer { defaults.removePersistentDomain(forName: suite) }
		#expect(FeedbackSoundPlayer.shared.duration(start: true, defaults: defaults) > 0)
	}

	@Test func outputDeviceCatalogListsNamedDevices() {
		for device in AudioOutputDeviceCatalog.outputDevices() {
			#expect(!device.uid.isEmpty)
			#expect(!device.name.isEmpty)
		}
	}
}
