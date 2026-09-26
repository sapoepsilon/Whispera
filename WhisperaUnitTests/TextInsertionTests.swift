import AppKit
import CoreGraphics
import CryptoKit
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

	var typedChunks: [String] = []

	func postUnicode(_ units: [UniChar]) {
		typedChunks.append(String(utf16CodeUnits: units, count: units.count))
	}

	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		events.append(
			Event(keyCode: keyCode, flags: flags, clipboardText: pasteboard.string(forType: .string)))
		if keyCode == KeyCode.v { onPaste?(pasteboard) }
	}
}

@MainActor
final class SlowReadingKeyPoster: KeyEventPosting {
	let pasteboard: NSPasteboard
	let readDelayMs: UInt64
	var pastedText: String?
	var readTask: Task<Void, Never>?

	init(pasteboard: NSPasteboard, readDelayMs: UInt64) {
		self.pasteboard = pasteboard
		self.readDelayMs = readDelayMs
	}

	nonisolated func postUnicode(_ units: [UniChar]) {}

	nonisolated func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		guard keyCode == KeyCode.v else { return }
		MainActor.assumeIsolated {
			readTask = Task { @MainActor in
				try? await Task.sleep(nanoseconds: readDelayMs * 1_000_000)
				pastedText = pasteboard.string(forType: .string)
			}
		}
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

/// Reads the pasteboard some time after Cmd-V, like an Electron app or a remote desktop.
final class LateReadingKeyPoster: KeyEventPosting {
	let pasteboard: NSPasteboard
	let delayMs: Int
	var readText: String?
	var readTask: Task<Void, Never>?

	init(pasteboard: NSPasteboard, delayMs: Int) {
		self.pasteboard = pasteboard
		self.delayMs = delayMs
	}

	func postUnicode(_ units: [UniChar]) {}

	func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
		guard keyCode == KeyCode.v, delayMs >= 0 else { return }
		readTask = Task { @MainActor [self] in
			try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
			readText = pasteboard.string(forType: .string)
		}
	}
}

@MainActor
struct ClipboardSafetyTests {
	@Test func slowAppStillPastesTheTranscriptNotTheOldClipboard() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("old private copy", forType: .string)
		let poster = LateReadingKeyPoster(pasteboard: pasteboard, delayMs: 400)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, readTimeoutMs: 3000,
			settingsProvider: { fastSettings { $0.pasteDelayAfterMs = 60 } })

		await inserter.insert("hello", context: .finalTranscript).value
		await poster.readTask?.value

		#expect(poster.readText == "hello", "A 60 ms timer would have restored the old clipboard first")
		#expect(pasteboard.string(forType: .string) == "old private copy")
	}

	@Test func restoresAfterTheTimeoutWhenNothingReads() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("old copy", forType: .string)
		let poster = LateReadingKeyPoster(pasteboard: pasteboard, delayMs: -1)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, readTimeoutMs: 100,
			settingsProvider: { fastSettings() })

		let clock = ContinuousClock()
		let start = clock.now
		await inserter.insert("hello", context: .finalTranscript).value

		#expect(clock.now - start >= .milliseconds(100))
		#expect(clock.now - start < .seconds(2))
		#expect(pasteboard.string(forType: .string) == "old copy")
	}

	@Test(arguments: [ClipboardSnapshot.concealedType, ClipboardWriter.transientType])
	func concealedPasswordIsNeverWrittenBack(marker: NSPasteboard.PasteboardType) async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let item = NSPasteboardItem()
		item.setString("hunter2", forType: .string)
		item.setData(Data(), forType: marker)
		pasteboard.clearContents()
		pasteboard.writeObjects([item])
		#expect(ClipboardSnapshot.inspect(pasteboard) == .sensitive)

		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })
		await inserter.insert("hello", context: .finalTranscript).value

		#expect(poster.events.first?.clipboardText == "hello")
		#expect(pasteboard.string(forType: .string) == nil, "The password must not be republished")
		#expect(pasteboard.pasteboardItems?.isEmpty ?? true)
	}

	@Test func oversizedClipboardIsNotSnapshotted() {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setData(Data(count: 4096), forType: .tiff)
		var limits = ClipboardSnapshot.Limits()
		limits.maxRepresentationBytes = 1024
		#expect(ClipboardSnapshot.inspect(pasteboard, limits: limits) == .tooLarge)

		limits = ClipboardSnapshot.Limits()
		limits.maxTotalBytes = 1024
		#expect(ClipboardSnapshot.inspect(pasteboard, limits: limits) == .tooLarge)

		guard case .captured(let snapshot) = ClipboardSnapshot.inspect(pasteboard) else {
			Issue.record("A 4 KB image fits the default limits")
			return
		}
		#expect(snapshot.byteCount == 4096)
	}

	@Test func promisedAndDynamicFlavorsAreNeverRead() {
		#expect(ClipboardSnapshot.isSkippedType(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
		#expect(ClipboardSnapshot.isSkippedType(NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8y")))
		#expect(ClipboardSnapshot.isSkippedType(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")))
		#expect(!ClipboardSnapshot.isSkippedType(.string))
		#expect(!ClipboardSnapshot.isSkippedType(.png))
	}

	@Test func backgroundInspectionMatchesForegroundInspection() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let background = await ClipboardSnapshot.inspectInBackground(pasteboard)
		#expect(background == ClipboardSnapshot.inspect(pasteboard))
	}

	@Test func receiptReportsTheFirstRead() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let receipt = PasteReadReceipt(text: "hello")
		ClipboardWriter.write(receipt, to: pasteboard, transient: true)
		#expect(!receipt.wasRead)
		#expect(pasteboard.types?.contains(ClipboardWriter.transientType) == true)
		#expect(pasteboard.string(forType: .string) == "hello")
		#expect(await receipt.waitForRead(timeoutMs: 10))
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

	@Test func waitsForASlowTargetAppToReadTheTranscriptBeforeRestoring() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let poster = SlowReadingKeyPoster(pasteboard: pasteboard, readDelayMs: 300)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })

		await inserter.insert("hello world", context: .finalTranscript).value
		await poster.readTask?.value

		#expect(poster.pastedText == "hello world")
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
	@Test func defaultsGiveTheTargetAppTimeAfterItReads() {
		let suite = "PasteDelaySettingsTests.defaults.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }

		let settings = TextInsertionSettings(defaults: defaults)
		#expect(settings.pasteDelayBeforeMs == 60)
		#expect(settings.pasteDelayAfterMs == 150)
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

struct TypingPlanTests {
	@Test func splitsLongTextIntoTwentyUnitEvents() {
		let text = String(repeating: "a", count: 45)
		let steps = TypingPlan.steps(for: text)
		let sizes = steps.compactMap { step -> Int? in
			if case .text(let units) = step { return units.count }
			return nil
		}
		#expect(sizes == [20, 20, 5])
	}

	@Test func neverSplitsASurrogatePairOrCluster() {
		let text = String(repeating: "a", count: 19) + "\u{1F600}" + "b"
		let steps = TypingPlan.steps(for: text)
		guard case .text(let first) = steps.first, case .text(let second) = steps.last else {
			Issue.record("expected two text steps, got \(steps)")
			return
		}
		#expect(first.count == 19)
		#expect(String(utf16CodeUnits: second, count: second.count) == "\u{1F600}b")
	}

	@Test func newlinesAreTypedAsSpacesSoTheyNeverPressReturn() {
		let text = "one\ntwo\r\nthree\n\n\nrm -rf ~\n"
		#expect(TypingPlan.flattenedLineBreaks(text) == "one two three rm -rf ~ ")
		let typed = TypingPlan.steps(for: text).map { step -> String in
			guard case .text(let units) = step else { return "" }
			#expect(units.count <= TypingPlan.maxUnitsPerEvent)
			return String(utf16CodeUnits: units, count: units.count)
		}
		#expect(typed.joined() == "one two three rm -rf ~ ")
	}

	@MainActor
	@Test func typedMultiLineTextPostsNoReturnKey() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: { fastSettings { $0.pasteMethod = .typeCharacters } })

		await inserter.insert("ls\nrm -rf ~\n", context: .finalTranscript).value

		#expect(poster.events.isEmpty, "No Return key may be posted for typed line breaks")
		#expect(poster.typedChunks.joined() == "ls rm -rf ~ ")
	}
}

@MainActor
struct PasteMethodTests {
	private func makeInserter(
		_ pasteboard: NSPasteboard, _ poster: RecordingKeyPoster,
		_ configure: @escaping (inout TextInsertionSettings) -> Void
	) -> TextInserter {
		TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings(configure) })
	}

	@Test func typeCharactersTypesWithoutTouchingTheClipboard() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let changeCount = pasteboard.changeCount
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = makeInserter(pasteboard, poster) { $0.pasteMethod = .typeCharacters }

		await inserter.insert("héllo wörld", context: .finalTranscript).value

		#expect(poster.typedChunks.joined() == "héllo wörld")
		#expect(poster.events.isEmpty)
		#expect(pasteboard.changeCount == changeCount)
	}

	@Test func typeCharactersWithKeepTranscriptAlsoCopies() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = makeInserter(pasteboard, poster) {
			$0.pasteMethod = .typeCharacters
			$0.clipboardHandling = .keepTranscript
		}

		await inserter.insert("typed", context: .finalTranscript).value

		#expect(pasteboard.string(forType: .string) == "typed")
	}

	@Test func copyOnlyLeavesTranscriptAndSendsNoKeys() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("user copy", forType: .string)
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = makeInserter(pasteboard, poster) { $0.pasteMethod = .copyOnly }

		await inserter.insert("copied", context: .finalTranscript).value

		#expect(poster.events.isEmpty)
		#expect(poster.typedChunks.isEmpty)
		#expect(pasteboard.string(forType: .string) == "copied")
	}

	@Test func liveSegmentsFallBackToPasteForNonInsertingMethods() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = makeInserter(pasteboard, poster) { $0.pasteMethod = .copyOnly }

		await inserter.insert(" live", context: .liveSegment).value

		#expect(poster.events.map(\.keyCode) == [KeyCode.v])
	}

	@Test func methodRoundTripsThroughDefaults() {
		let suite = "PasteMethodTests.roundtrip.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }
		#expect(TextInsertionSettings(defaults: defaults).pasteMethod == .commandV)

		var settings = TextInsertionSettings()
		settings.pasteMethod = .externalScript
		settings.externalScriptPath = "/usr/local/bin/insert.sh"
		settings.save(to: defaults)

		let loaded = TextInsertionSettings(defaults: defaults)
		#expect(loaded.pasteMethod == .externalScript)
		#expect(loaded.externalScriptPath == "/usr/local/bin/insert.sh")
	}
}

struct ExternalScriptRunnerTests {
	private let keyStore = InMemoryScriptApprovalKeyStore()

	private func makeScript(_ body: String) throws -> (script: URL, directory: URL) {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("whispera-script-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		let script = directory.appendingPathComponent("insert.sh")
		try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		return (script, directory)
	}

	private func approveAndRun(_ script: URL, text: String, timeout: TimeInterval = 10) async throws {
		let approval = try ScriptApproval.approve(path: script.path, keyStore: keyStore)
		try await ExternalScriptRunner.run(
			path: script.path, approval: approval, text: text, timeout: timeout, keyStore: keyStore)
	}

	@Test func passesTranscriptOnStdinAndEnvironmentButNotArgv() async throws {
		let (script, directory) = try makeScript(
			"printf '%s|%s|%s' \"$#\" \"$(cat)\" \"$WHISPERA_TRANSCRIPT\" > \"$(dirname \"$0\")/out.txt\"\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		try await approveAndRun(script, text: "it's \"quoted\" text")

		let output = try String(contentsOf: directory.appendingPathComponent("out.txt"), encoding: .utf8)
		#expect(output == "0|it's \"quoted\" text|it's \"quoted\" text")
	}

	@Test func runsWithAMinimalEnvironment() async throws {
		let (script, directory) = try makeScript("env > \"$(dirname \"$0\")/env.txt\"\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		try await approveAndRun(script, text: "x")

		let output = try String(contentsOf: directory.appendingPathComponent("env.txt"), encoding: .utf8)
		let names = Set(output.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
		let allowed: Set<String> = [
			"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
			ExternalScriptRunner.transcriptEnvironmentKey, "PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING",
		]
		#expect(names.subtracting(allowed).isEmpty, "Leaked: \(names.subtracting(allowed).sorted())")
		#expect(names.contains(ExternalScriptRunner.transcriptEnvironmentKey))
	}

	@Test func refusesAPathThatWasNeverApprovedInSettings() async throws {
		let (script, directory) = try makeScript("touch \"$(dirname \"$0\")/ran\"\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		// What `defaults write ... externalScriptPath /tmp/x` produces: a path with no approval
		await #expect(throws: ExternalScriptError.notApproved) {
			try await ExternalScriptRunner.run(path: script.path, approval: "", text: "x", keyStore: keyStore)
		}
		// Or an approval forged without the Keychain key
		let forged = try ScriptApproval.approve(path: script.path, keyStore: InMemoryScriptApprovalKeyStore())
		await #expect(throws: ExternalScriptError.notApproved) {
			try await ExternalScriptRunner.run(path: script.path, approval: forged, text: "x", keyStore: keyStore)
		}
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
	}

	@Test func refusesAScriptThatChangedAfterItWasApproved() async throws {
		let (script, directory) = try makeScript("exit 0\n")
		defer { try? FileManager.default.removeItem(at: directory) }
		let approval = try ScriptApproval.approve(path: script.path, keyStore: keyStore)

		try "#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\n".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

		await #expect(throws: ExternalScriptError.notApproved) {
			try await ExternalScriptRunner.run(path: script.path, approval: approval, text: "x", keyStore: keyStore)
		}
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
	}

	@Test func refusesAnApprovalCopiedToAnotherScript() async throws {
		let (first, firstDirectory) = try makeScript("exit 0\n")
		let (second, secondDirectory) = try makeScript("exit 0\n")
		defer {
			try? FileManager.default.removeItem(at: firstDirectory)
			try? FileManager.default.removeItem(at: secondDirectory)
		}
		let approval = try ScriptApproval.approve(path: first.path, keyStore: keyStore)
		#expect(ScriptApproval.isApproved(path: first.path, approval: approval, keyStore: keyStore))
		#expect(!ScriptApproval.isApproved(path: second.path, approval: approval, keyStore: keyStore))
	}

	@Test func refusesScriptsOtherUsersCanWrite() throws {
		let (script, directory) = try makeScript("exit 0\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: script.path)
		#expect(throws: ExternalScriptError.unsafePermissions("it is writable by other users")) {
			try ScriptApproval.approve(path: script.path, keyStore: keyStore)
		}

		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
		#expect(throws: ExternalScriptError.unsafePermissions("its folder is writable by other users")) {
			try ScriptApproval.approve(path: script.path, keyStore: keyStore)
		}
	}

	@Test func nonZeroExitIsAnError() async throws {
		let (script, directory) = try makeScript("exit 3\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		await #expect(throws: ExternalScriptError.failed(exitCode: 3)) {
			try await approveAndRun(script, text: "x")
		}
	}

	@Test func hungScriptTimesOut() async throws {
		let (script, directory) = try makeScript("sleep 5\n")
		defer { try? FileManager.default.removeItem(at: directory) }

		await #expect(throws: ExternalScriptError.timedOut) {
			try await approveAndRun(script, text: "x", timeout: 0.3)
		}
	}

	@Test func timeoutKillsTheWholeProcessGroupEvenWhenSIGTERMIsIgnored() async throws {
		let (script, directory) = try makeScript(
			"""
			trap '' TERM
			sleep 30 &
			echo $! > "$(dirname "$0")/child.pid"
			echo $$ > "$(dirname "$0")/parent.pid"
			while :; do sleep 1; done

			""")
		defer { try? FileManager.default.removeItem(at: directory) }

		await #expect(throws: ExternalScriptError.timedOut) {
			try await approveAndRun(script, text: "x", timeout: 0.5)
		}
		try await Task.sleep(nanoseconds: UInt64((ExternalScriptRunner.terminationGrace + 1) * 1_000_000_000))

		for name in ["parent.pid", "child.pid"] {
			let raw = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
			let pid = try #require(pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
			#expect(kill(pid, 0) != 0, "\(name) \(pid) is still running")
		}
	}

	@Test func rejectsMissingOrNonExecutablePaths() throws {
		#expect(throws: ExternalScriptError.notConfigured) {
			try ExternalScriptRunner.validate(path: "  ")
		}
		#expect(throws: ExternalScriptError.notExecutable("/nonexistent/whispera-script")) {
			try ExternalScriptRunner.validate(path: "/nonexistent/whispera-script")
		}
	}

	@MainActor
	@Test func failedScriptLeavesTranscriptOnClipboard() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: {
				fastSettings {
					$0.pasteMethod = .externalScript
					$0.externalScriptPath = "/nonexistent/whispera-script"
				}
			})

		await inserter.insert("rescued", context: .finalTranscript).value

		#expect(pasteboard.string(forType: .string) == "rescued")
	}
}

@MainActor
struct AutoSubmitTests {
	private func run(
		_ context: InsertionContext = .finalTranscript,
		_ configure: @escaping (inout TextInsertionSettings) -> Void
	) async -> RecordingKeyPoster {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings(configure) })
		await inserter.insert("send this", context: context).value
		return poster
	}

	@Test func offByDefault() async {
		let poster = await run { _ in }
		#expect(poster.events.map(\.keyCode) == [KeyCode.v])
	}

	@Test(arguments: AutoSubmitKey.allCases)
	func pressesTheChosenKeyAfterPasting(key: AutoSubmitKey) async {
		let poster = await run {
			$0.autoSubmit = true
			$0.autoSubmitKey = key
		}
		#expect(poster.events.count == 2)
		#expect(poster.events.last?.keyCode == KeyCode.returnKey)
		#expect(poster.events.last?.flags == key.flags)
	}

	@Test func submitsAfterTypedText() async {
		let poster = await run {
			$0.autoSubmit = true
			$0.pasteMethod = .typeCharacters
		}
		#expect(poster.typedChunks.joined() == "send this")
		#expect(poster.events.map(\.keyCode) == [KeyCode.returnKey])
	}

	@Test func neverSubmitsIndividualLiveSegmentsOrCopyOnly() async {
		let live = await run(.liveSegment) { $0.autoSubmit = true }
		#expect(live.events.map(\.keyCode) == [KeyCode.v])

		let copyOnly = await run {
			$0.autoSubmit = true
			$0.pasteMethod = .copyOnly
		}
		#expect(copyOnly.events.isEmpty)
	}

	@Test func liveSessionSubmitsOnceAfterItsLastSegment() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: {
				fastSettings {
					$0.autoSubmit = true
					$0.autoSubmitKey = .commandReturn
					$0.pasteMethod = .copyOnly
				}
			})

		inserter.insert(" first part", context: .liveSegment)
		inserter.insert(" second part", context: .liveSegment)
		await inserter.submitAfterLiveSession().value

		#expect(poster.events.map(\.keyCode) == [KeyCode.v, KeyCode.v, KeyCode.returnKey])
		#expect(poster.events.last?.flags == AutoSubmitKey.commandReturn.flags)
	}

	@Test func liveSessionDoesNotSubmitWhenAutoSubmitIsOff() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, settingsProvider: { fastSettings() })

		inserter.insert(" words", context: .liveSegment)
		await inserter.submitAfterLiveSession().value

		#expect(poster.events.map(\.keyCode) == [KeyCode.v])
	}

	@Test func skipsSubmitWhenTheScriptFails() async {
		let poster = await run {
			$0.autoSubmit = true
			$0.pasteMethod = .externalScript
			$0.externalScriptPath = "/nonexistent/whispera-script"
		}
		#expect(poster.events.isEmpty)
	}

	@Test func settingsRoundTrip() {
		let suite = "AutoSubmitTests.roundtrip.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }
		#expect(!TextInsertionSettings(defaults: defaults).autoSubmit)

		var settings = TextInsertionSettings()
		settings.autoSubmit = true
		settings.autoSubmitKey = .commandReturn
		settings.save(to: defaults)

		let loaded = TextInsertionSettings(defaults: defaults)
		#expect(loaded.autoSubmit)
		#expect(loaded.autoSubmitKey == .commandReturn)
	}
}

struct TrailingSpaceTests {
	private func settings(_ enabled: Bool) -> TextInsertionSettings {
		var settings = TextInsertionSettings()
		settings.appendTrailingSpace = enabled
		return settings
	}

	@Test func offByDefaultLeavesTextAlone() {
		#expect(TextInsertionSettings().preparedText("Hello.", for: .finalTranscript) == "Hello.")
	}

	@Test func appendsOneSpaceToFinalTranscripts() {
		#expect(settings(true).preparedText("Hello.", for: .finalTranscript) == "Hello. ")
	}

	@Test func doesNotDoubleUpExistingWhitespace() {
		#expect(settings(true).preparedText("Hello. ", for: .finalTranscript) == "Hello. ")
		#expect(settings(true).preparedText("Line\n", for: .finalTranscript) == "Line\n")
	}

	@Test func leavesLiveSegmentsAlone() {
		#expect(settings(true).preparedText(" segment", for: .liveSegment) == " segment")
	}

	@MainActor
	@Test func insertedTextCarriesTheSpace() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster,
			settingsProvider: { fastSettings { $0.appendTrailingSpace = true } })

		await inserter.insert("Hello.", context: .finalTranscript).value

		#expect(poster.events.first?.clipboardText == "Hello. ")
	}

	@Test func settingRoundTrips() {
		let suite = "TrailingSpaceTests.roundtrip.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defer { defaults.removePersistentDomain(forName: suite) }
		#expect(!TextInsertionSettings(defaults: defaults).appendTrailingSpace)

		settings(true).save(to: defaults)
		#expect(TextInsertionSettings(defaults: defaults).appendTrailingSpace)
	}
}

final class InMemoryScriptApprovalKeyStore: ScriptApprovalKeyStore, @unchecked Sendable {
	private let lock = NSLock()
	private var stored: SymmetricKey?

	func key(createIfMissing: Bool) throws -> SymmetricKey? {
		lock.lock()
		defer { lock.unlock() }
		if stored == nil, createIfMissing {
			stored = SymmetricKey(size: .bits256)
		}
		return stored
	}
}
