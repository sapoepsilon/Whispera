import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Whispera

final class RecordingKeyPoster: KeyEventPosting {
	struct Event: Equatable {
		let keyCode: CGKeyCode
		let flags: CGEventFlags
		let clipboardText: String?
	}

	let pasteboard: NSPasteboard
	var events: [Event] = []
	var onPaste: ((NSPasteboard) -> Void)?

	init(pasteboard: NSPasteboard) {
		self.pasteboard = pasteboard
	}

	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		events.append(
			Event(keyCode: keyCode, flags: flags, clipboardText: pasteboard.string(forType: .string)))
		if keyCode == KeyCode.v { onPaste?(pasteboard) }
	}
}

private func makePasteboard() -> NSPasteboard {
	NSPasteboard(name: NSPasteboard.Name("whispera.tests.\(UUID().uuidString)"))
}

private func fastSettings(_ configure: (inout TextInsertionSettings) -> Void = { _ in })
	-> TextInsertionSettings
{
	var settings = TextInsertionSettings()
	settings.pasteDelayBeforeMs = 0
	settings.pasteDelayAfterMs = 0
	configure(&settings)
	return settings
}

@MainActor
struct ClipboardSnapshotTests {
	@Test func roundTripsEveryItemAndType() {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let first = NSPasteboardItem()
		first.setString("hello", forType: .string)
		first.setData(Data([1, 2, 3]), forType: .png)
		let second = NSPasteboardItem()
		second.setString("https://example.com", forType: .URL)
		pasteboard.clearContents()
		pasteboard.writeObjects([first, second])

		let snapshot = ClipboardSnapshot.capture(from: pasteboard)
		ClipboardWriter.write("transcript", to: pasteboard, transient: true)
		snapshot.restore(to: pasteboard)

		let items = pasteboard.pasteboardItems ?? []
		#expect(items.count == 2)
		#expect(items.first?.string(forType: .string) == "hello")
		#expect(items.first?.data(forType: .png) == Data([1, 2, 3]))
		#expect(items.last?.string(forType: .URL) == "https://example.com")
	}

	@Test func restoringAnEmptySnapshotClearsTheTranscript() {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		let snapshot = ClipboardSnapshot.capture(from: pasteboard)
		#expect(snapshot.isEmpty)

		ClipboardWriter.write("transcript", to: pasteboard, transient: true)
		snapshot.restore(to: pasteboard)

		#expect(pasteboard.string(forType: .string) == nil)
	}

	@Test func transientWriteIsMarkedForClipboardManagers() {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		ClipboardWriter.write("secret", to: pasteboard, transient: true)
		#expect(pasteboard.types?.contains(ClipboardWriter.transientType) == true)

		ClipboardWriter.write("kept", to: pasteboard, transient: false)
		#expect(pasteboard.types?.contains(ClipboardWriter.transientType) == false)
	}

	@Test func restoreOnlyWhenNothingElseWroteToTheClipboard() {
		#expect(ClipboardWriter.shouldRestore(currentChangeCount: 5, changeCountAfterWrite: 5))
		#expect(!ClipboardWriter.shouldRestore(currentChangeCount: 6, changeCountAfterWrite: 5))
	}
}

@MainActor
struct TextInserterClipboardTests {
	@Test func pastesTranscriptThenRestoresPreviousClipboard() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })

		await inserter.insert("hello world", context: .finalTranscript).value

		#expect(
			poster.events == [
				.init(keyCode: KeyCode.v, flags: .maskCommand, clipboardText: "hello world")
			])
		#expect(pasteboard.string(forType: .string) == "user copy")
	}

	@Test func keepTranscriptLeavesItOnTheClipboard() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: { fastSettings { $0.clipboardHandling = .keepTranscript } })

		await inserter.insert("hello world", context: .finalTranscript).value

		#expect(pasteboard.string(forType: .string) == "hello world")
		#expect(pasteboard.types?.contains(ClipboardWriter.transientType) == false)
	}

	@Test func doesNotClobberAClipboardChangeMadeDuringThePaste() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("old copy", forType: .string)
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		poster.onPaste = { board in
			board.clearContents()
			board.setString("copied mid-paste", forType: .string)
		}
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })

		await inserter.insert("hello", context: .finalTranscript).value

		#expect(pasteboard.string(forType: .string) == "copied mid-paste")
	}

	@Test func liveSegmentsAreSerializedAndEachSeesItsOwnText() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: { fastSettings { $0.pasteDelayAfterMs = 20 } })

		inserter.insert(" one", context: .liveSegment)
		await inserter.insert(" two", context: .liveSegment).value

		#expect(poster.events.map(\.clipboardText) == [" one", " two"])
		#expect(pasteboard.string(forType: .string) == "user copy")
	}

	@Test func emptyTextDoesNothing() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })

		await inserter.insert("", context: .finalTranscript).value

		#expect(poster.events.isEmpty)
	}
}

struct TextInsertionSettingsPersistenceTests {
	@Test func defaultsRestoreTheClipboard() {
		let suite = "TextInsertionSettingsTests.defaults.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		let settings = TextInsertionSettings(defaults: defaults)
		#expect(settings.clipboardHandling == .restore)
	}

	@Test func clipboardHandlingRoundTrips() {
		let suite = "TextInsertionSettingsTests.roundtrip.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		var settings = TextInsertionSettings()
		settings.clipboardHandling = .keepTranscript
		settings.save(to: defaults)

		#expect(TextInsertionSettings(defaults: defaults).clipboardHandling == .keepTranscript)
	}
}

struct PasteDelaySettingsTests {
	@Test func defaultsToSixtyMillisecondsEachSide() {
		let suite = "PasteDelaySettingsTests.defaults.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		let settings = TextInsertionSettings(defaults: defaults)
		#expect(settings.pasteDelayBeforeMs == 60)
		#expect(settings.pasteDelayAfterMs == 60)
	}

	@Test func delaysRoundTripAndClamp() {
		let suite = "PasteDelaySettingsTests.roundtrip.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		defaults.set(250, forKey: TextInsertionSettings.Keys.pasteDelayBeforeMs)
		defaults.set(5000, forKey: TextInsertionSettings.Keys.pasteDelayAfterMs)
		var settings = TextInsertionSettings(defaults: defaults)
		#expect(settings.pasteDelayBeforeMs == 250)
		#expect(settings.pasteDelayAfterMs == 1000)

		settings.pasteDelayBeforeMs = -20
		settings.save(to: defaults)
		#expect(TextInsertionSettings(defaults: defaults).pasteDelayBeforeMs == 0)
	}

	@MainActor
	@Test func inserterWaitsForBothDelays() async throws {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let clock = ContinuousClock()
		let start = clock.now
		var pasteAt: ContinuousClock.Instant?
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		poster.onPaste = { _ in pasteAt = clock.now }
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: {
				fastSettings {
					$0.pasteDelayBeforeMs = 120
					$0.pasteDelayAfterMs = 150
				}
			})

		await inserter.insert("hello", context: .finalTranscript).value
		let finished = clock.now

		let pastedAt = try #require(pasteAt)
		let beforePaste = pastedAt - start
		#expect(beforePaste >= .milliseconds(120))
		#expect(finished - pastedAt >= .milliseconds(150))
		#expect(pasteboard.string(forType: .string) == "user copy")
	}
}
