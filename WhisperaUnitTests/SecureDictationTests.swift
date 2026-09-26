import AppKit
import Foundation
import Testing

@testable import Whispera

struct SecureDictationPolicyTests {
	@Test func secureInputKeepsTheDictationOutOfHistoryTheLLMAndCopyLast() {
		let policy = SecureDictationPolicy.resolve(postProcessRequested: true, secureInput: true)
		#expect(!policy.postProcess)
		#expect(!policy.saveToHistory)
		#expect(!policy.rememberAsLastTranscription)
		#expect(policy.concealClipboard)
	}

	@Test func normalDictationIsUnchanged() {
		let policy = SecureDictationPolicy.resolve(postProcessRequested: true, secureInput: false)
		#expect(policy.postProcess)
		#expect(policy.saveToHistory)
		#expect(policy.rememberAsLastTranscription)
		#expect(!policy.concealClipboard)
		#expect(!SecureDictationPolicy.resolve(postProcessRequested: false, secureInput: false).postProcess)
	}
}

@MainActor
struct SecureDictationInsertionTests {
	private func makePasteboard() -> NSPasteboard {
		NSPasteboard(name: NSPasteboard.Name("whispera.secure.tests.\(UUID().uuidString)"))
	}

	private func settings(_ configure: (inout TextInsertionSettings) -> Void = { _ in }) -> TextInsertionSettings {
		var settings = TextInsertionSettings()
		settings.pasteDelayBeforeMs = 0
		settings.pasteDelayAfterMs = 0
		configure(&settings)
		return settings
	}

	@Test func concealedPasteIsMarkedForClipboardManagersAndNotKept() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		var typesAtPaste: [NSPasteboard.PasteboardType] = []
		poster.onPaste = { typesAtPaste = $0.pasteboardItems?.first?.types ?? [] }
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, readTimeoutMs: 200,
			isSecureInputActive: { false },
			settingsProvider: { settings { $0.clipboardHandling = .keepTranscript } })

		await inserter.insert("hunter2", context: .finalTranscript, concealed: true).value

		#expect(poster.events.first?.clipboardText == "hunter2")
		#expect(typesAtPaste.contains(ClipboardWriter.concealedType))
		#expect(typesAtPaste.contains(ClipboardWriter.transientType))
		#expect(pasteboard.string(forType: .string) == nil, "Keep transcript must not leave a password behind")
	}

	@Test func liveSegmentsAreConcealedWhileSecureInputIsOn() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		var typesAtPaste: [NSPasteboard.PasteboardType] = []
		poster.onPaste = { typesAtPaste = $0.pasteboardItems?.first?.types ?? [] }
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, readTimeoutMs: 200,
			isSecureInputActive: { true }, settingsProvider: { settings() })

		await inserter.insert(" secret", context: .liveSegment).value

		#expect(typesAtPaste.contains(ClipboardWriter.concealedType))
	}

	@Test func typedSecretIsNotCopiedEvenWithKeepTranscript() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		let changeCount = pasteboard.changeCount
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, isSecureInputActive: { true },
			settingsProvider: {
				settings {
					$0.pasteMethod = .typeCharacters
					$0.clipboardHandling = .keepTranscript
				}
			})

		await inserter.insert("hunter2", context: .finalTranscript).value

		#expect(poster.typedChunks.joined() == "hunter2")
		#expect(pasteboard.changeCount == changeCount)
	}

	@Test func copyOnlySecretIsConcealed() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, isSecureInputActive: { true },
			settingsProvider: { settings { $0.pasteMethod = .copyOnly } })

		await inserter.insert("hunter2", context: .finalTranscript).value

		let types = pasteboard.pasteboardItems?.first?.types ?? []
		#expect(types.contains(ClipboardWriter.concealedType))
		#expect(ClipboardSnapshot.isSensitive(types: types))
	}

	@Test func normalPasteHasNoConcealedMarker() async {
		let pasteboard = makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let poster = RecordingKeyPoster(pasteboard: pasteboard)
		var typesAtPaste: [NSPasteboard.PasteboardType] = []
		poster.onPaste = { typesAtPaste = $0.pasteboardItems?.first?.types ?? [] }
		let inserter = TextInserter(
			pasteboard: pasteboard, keyPoster: poster, readTimeoutMs: 200,
			isSecureInputActive: { false },
			settingsProvider: { settings { $0.clipboardHandling = .keepTranscript } })

		await inserter.insert("hello", context: .finalTranscript).value

		#expect(!typesAtPaste.contains(ClipboardWriter.concealedType))
		#expect(pasteboard.string(forType: .string) == "hello")
	}
}

struct SecureInputPostProcessingNoticeTests {
	@Test func onlyWhenPostProcessingWasAskedForUnderSecureInput() {
		let notice = SecureDictationPolicy.skippedPostProcessingNotice
		#expect(notice(true, true) != nil)
		#expect(notice(true, false) == nil)
		#expect(notice(false, true) == nil)
	}
}
