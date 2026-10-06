import AppKit
import Foundation
import Testing

@testable import Whispera

struct NewStringsAreLocalizedTests {
	/// Strings added for these fixes, which LocalizationCatalogTests then checks are translated.
	static let keys = [
		"Push: named",
		// The account device confirmation card (safety number)
		"It joined your account. It can't reach this Mac until you confirm it here.",
		"Not available yet",
		"Mac fingerprint: %@",
		"Numbers Match — Confirm with Touch ID",
		"Safety number — must match the one on your iPhone",
		"The Mac link didn't send a safety number for this iPhone. Try again.",
		"This device's keys changed. If you didn't reinstall Whispera on it, don't confirm.",
		"This iPhone's keys changed while the card was open. Compare the new safety number before you confirm.",
		"Push: generic",
		"Last used",
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
		// The redesigned menu bar popover, status menu and onboarding
		"Press %@ to dictate",
		"Microphone access is off",
		"Accessibility access is off",
		"Transcription Activity",
		"Transcription Activity…",
		"Settings…",
		"1 file · %lld processing",
		"%lld files · %lld processing",
		"Whispera Settings",
		"Configure Whispera",
		"Press %@ anywhere",
		"Your voice, transcribed locally",
		"No transcript yet",
		"Copied the last transcript",
		// The Mac approval card
		"Approve secret access?",
		"%@ left",
		"Agent (claimed by requester)",
		"Mac (claimed by requester)",
		"Read token",
		"Write token",
		"%@ token",
		"Request",
		"Operation",
		"Secret",
		"Project",
		"Deny",
		"Approve with Touch ID",
		"Too late to approve here.",
		"Touch ID was cancelled. Nothing was sent.",
		"This Mac's approval key is missing. Set it up again in Settings.",
		"Approved.",
		"Denied.",
		"Approved with Touch ID.",
		"Approved on your iPhone.",
		"Denied with Touch ID.",
		"Denied on your iPhone.",
		"The broker refused this approval (%@).",
		"The request was withdrawn.",
		"The request expired.",
		"Couldn't finish here. Approve with Touch ID or on your iPhone.",
		"This Mac approves as %@ · key %@",
		"Pin it once in Terminal; bws-touchid asks for Touch ID and the last 4 characters of the key.",
		"Copy Command",
		"Approve Secret Requests on This Mac…",
		"Shows a card with Touch ID when an agent asks the broker for a secret.",
		"Couldn't set up approvals on this Mac",
		"The Mac link isn't running. Turn it on above, then try again.",
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
