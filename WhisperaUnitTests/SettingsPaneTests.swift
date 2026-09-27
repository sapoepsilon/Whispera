import AppKit
import Testing

@testable import Whispera

struct SettingsPaneTests {
	private static let shippedLanguages = ["en", "es", "de", "fr"]

	private static func bundle(for language: String) throws -> Bundle {
		let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
		return try #require(Bundle(path: path))
	}

	@Test func sidebarKeepsTheOldTabOrder() {
		#expect(
			SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: true) == [
				.general, .textInsertion, .storage, .liveTranscription, .fileTranscription, .history, .automation,
				.benchmark, .postProcessing, .debug,
			])
	}

	@Test func debugRowOnlyAppearsInDebugMode() {
		#expect(!SettingsPane.visible(debugModeEnabled: false, liveTranscriptionEnabled: true).contains(.debug))
		#expect(SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: false).contains(.debug))
	}

	@Test func liveTranscriptionRowOnlyAppearsWhileStreamingIsOn() {
		#expect(
			!SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: false).contains(.liveTranscription))
		#expect(
			SettingsPane.visible(debugModeEnabled: false, liveTranscriptionEnabled: true).contains(.liveTranscription))
	}

	@Test func hiddenSelectionFallsBackToGeneral() {
		let visible = SettingsPane.visible(debugModeEnabled: false, liveTranscriptionEnabled: false)
		#expect(SettingsPane.resolve(.debug, visible: visible) == .general)
		#expect(SettingsPane.resolve(.liveTranscription, visible: visible) == .general)
		#expect(SettingsPane.resolve(nil, visible: visible) == .general)
		#expect(SettingsPane.resolve(.history, visible: visible) == .history)
	}

	@Test func everyPaneHasAValidSymbolAndUniqueIdentifier() {
		for pane in SettingsPane.allCases {
			#expect(NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil) != nil, "\(pane)")
		}
		let identifiers = Set(SettingsPane.allCases.map(\.accessibilityIdentifier))
		#expect(identifiers.count == SettingsPane.allCases.count)
	}

	@Test func everyPaneTitleIsTranslated() throws {
		let english = try Self.bundle(for: "en")
		let englishTitles = SettingsPane.allCases.map { $0.title(bundle: english) }
		for language in ["es", "de", "fr"] {
			let bundle = try Self.bundle(for: language)
			let titles = SettingsPane.allCases.map { $0.title(bundle: bundle) }
			let hasEmptyTitle = titles.contains { $0.isEmpty }
			#expect(!hasEmptyTitle, "\(language)")
			#expect(titles != englishTitles, "\(language)")
		}
		let french = try Self.bundle(for: "fr")
		let spanish = try Self.bundle(for: "es")
		#expect(SettingsPane.storage.title(bundle: french) == "Stockage et téléchargements")
		#expect(SettingsPane.storage.title(bundle: spanish) == "Almacenamiento y descargas")
	}

	/// The tab bar pushed French and Spanish tabs into a disabled overflow menu; the sidebar must
	/// instead grow to fit the longest row label in every shipped language.
	@Test(arguments: [1, 2, 3])
	func sidebarFitsTheLongestLabelInEveryLanguage(sizeMode: Int) throws {
		let font = NSFont.systemFont(ofSize: SettingsLayout.sidebarFontSize(sizeMode: sizeMode))
		var widths: [String: CGFloat] = [:]
		for language in Self.shippedLanguages {
			let bundle = try Self.bundle(for: language)
			let titles = SettingsPane.allCases.map { $0.title(bundle: bundle) }
			let sidebar = SettingsLayout.sidebarWidth(forTitles: titles, font: font)
			for title in titles {
				let label = (title as NSString).size(withAttributes: [.font: font]).width
				#expect(sidebar - SettingsLayout.sidebarRowChrome >= label, "\(language): \(title)")
			}
			widths[language] = sidebar
		}
		let english = try #require(widths["en"])
		let french = try #require(widths["fr"])
		#expect(french >= english)
	}

	@Test func largerSidebarIconSizesUseLargerText() {
		#expect(SettingsLayout.sidebarFontSize(sizeMode: 1) < SettingsLayout.sidebarFontSize(sizeMode: 2))
		#expect(SettingsLayout.sidebarFontSize(sizeMode: 2) < SettingsLayout.sidebarFontSize(sizeMode: 3))
		#expect(SettingsLayout.sidebarFontSize(sizeMode: 0) == SettingsLayout.sidebarFontSize(sizeMode: 2))
	}

	@Test func windowKeepsRoomForTheDetailPane() {
		let sidebar: CGFloat = 250
		#expect(SettingsLayout.minimumWindowWidth(sidebarWidth: sidebar) == sidebar + SettingsLayout.minimumDetailWidth)
		#expect(
			SettingsLayout.idealWindowWidth(sidebarWidth: sidebar)
				> SettingsLayout.minimumWindowWidth(sidebarWidth: sidebar))
	}

	@Test func tooSmallWindowsGrowToTheMinimumOnly() {
		let minimum = NSSize(width: 740, height: 520)
		#expect(SettingsLayout.size(NSSize(width: 600, height: 400), atLeast: minimum) == minimum)
		#expect(
			SettingsLayout.size(NSSize(width: 900, height: 400), atLeast: minimum) == NSSize(width: 900, height: 520))
		let roomy = NSSize(width: 1000, height: 700)
		#expect(SettingsLayout.size(roomy, atLeast: minimum) == roomy)
	}
}
