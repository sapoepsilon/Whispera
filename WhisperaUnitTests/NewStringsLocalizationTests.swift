import AppKit
import Foundation
import Testing

@testable import Whispera

struct NewStringsAreLocalizedTests {
	/// Strings added for these fixes, which LocalizationCatalogTests then checks are translated.
	static let keys = [
		"Microphone Access Required",
		"Whispera needs access to your microphone to transcribe audio. Please grant permission in System Settings > Privacy & Security > Microphone.",
		"Open System Settings",
		"Cancel",
		"Minimum Hold After Paste",
		"The transcript stays on the clipboard at least this long after Cmd-V before the previous clipboard returns",
		"Whispera couldn't paste because Accessibility access is off. The transcript is on the clipboard. Turn Whispera on in System Settings > Privacy & Security > Accessibility.",
		"Whispera couldn't type because Accessibility access is off. Turn Whispera on in System Settings > Privacy & Security > Accessibility.",
		"No app took the paste, so the transcript was left on the clipboard. Click where the text should go and press Cmd-V.",
		"No app took the paste. Secure Input was on, so the text was not kept on the clipboard.",
		"Secure Input was on, so this dictation was pasted as spoken: it was not post-processed or saved to history.",
		"No speech detected - clip skipped. Skip Silence (Settings > General > Microphone) drops clips it hears as silence; if you did speak, raise Speech Sensitivity or turn Skip Silence off.",
		"The shortcut \"%@\" could not be read, so it was reset to %@. Choose another one in Settings > General.",
		"History is on: Whispera keeps your recent transcripts on this Mac so you can copy or retry them. Recordings are not kept unless you turn that on. You can change this any time in Settings > History.",
		"Turn Off History",
		"Keep On",
		"Cancel Transcription",
		"Cancel and discard",
		"That key can't be used. Press Command, Option, Control or Shift + another key",
		"%@ is still loading, so this dictation could not be transcribed. Try again once it is ready, or pick another model in Settings.",
		"The model is still loading, so this dictation could not be transcribed. Try again once it is ready, or pick another model in Settings.",
	]

	@Test func everyNewStringIsInTheCatalog() throws {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("MiscUI/Localizable.xcstrings")
		let json = try #require(
			try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
		let strings = try #require(json["strings"] as? [String: Any])
		for key in Self.keys {
			#expect(strings[key] != nil, "\(key) is missing from Localizable.xcstrings")
		}
	}
}
