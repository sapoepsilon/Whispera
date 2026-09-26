import Testing

@testable import Whispera

struct SettingsWindowLocatorTests {
	@Test func matchesTheSwiftUISettingsIdentifierWhateverTheTitle() {
		#expect(
			SettingsWindowLocator.isSettingsWindow(
				identifier: SettingsWindowLocator.swiftUIIdentifier, title: "Allgemein", className: "NSWindow"))
	}

	@Test func matchesEnglishTabTitlesAsAFallback() {
		#expect(SettingsWindowLocator.isSettingsWindow(identifier: nil, title: "General", className: "NSWindow"))
		#expect(
			SettingsWindowLocator.isSettingsWindow(
				identifier: nil, title: "Storage & Downloads", className: "NSWindow"))
	}

	@Test func ignoresOtherWhisperaWindows() {
		for title in ["Transcription History", "What's New in Whispera", "Whispera Setup", ""] {
			#expect(!SettingsWindowLocator.isSettingsWindow(identifier: nil, title: title, className: "NSWindow"), "\(title)")
		}
	}
}
