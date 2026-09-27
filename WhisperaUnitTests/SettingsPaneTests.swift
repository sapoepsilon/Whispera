import AppKit
import SwiftUI
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

	@Test func openedPanesStayMountedUntilHidden() {
		let all = SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: true)
		#expect(SettingsPane.mounted(opened: [], current: .general, visible: all) == [.general])
		#expect(
			SettingsPane.mounted(opened: [.general, .benchmark], current: .history, visible: all) == [
				.general, .history, .benchmark,
			])
		let withoutDebug = SettingsPane.visible(debugModeEnabled: false, liveTranscriptionEnabled: true)
		#expect(
			SettingsPane.mounted(opened: [.general, .debug], current: .general, visible: withoutDebug) == [.general])
	}

	@Test func everyPaneHasAValidSymbolAndUniqueIdentifier() {
		for pane in SettingsPane.allCases {
			#expect(NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil) != nil, "\(pane)")
		}
		let identifiers = Set(SettingsPane.allCases.map(\.accessibilityIdentifier))
		#expect(identifiers.count == SettingsPane.allCases.count)
	}

	@Test(arguments: ["es", "de", "fr"])
	func everyPaneTitleIsTranslated(language: String) throws {
		let english = try Self.bundle(for: "en")
		let bundle = try Self.bundle(for: language)
		let missing = "\u{0}missing"
		for pane in SettingsPane.allCases {
			let key = pane.title(bundle: english)
			let translated = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
			#expect(translated != missing, "\(language) has no translation for \(key)")
			#expect(!translated.isEmpty, "\(language): \(key)")
		}
		let french = try Self.bundle(for: "fr")
		let spanish = try Self.bundle(for: "es")
		#expect(SettingsPane.storage.title(bundle: french) == "Stockage et téléchargements")
		#expect(SettingsPane.storage.title(bundle: spanish) == "Almacenamiento y descargas")
	}

	/// Selection highlight insets plus the list column's own padding, which the sidebar needs
	/// beyond the label itself (icon, gap and text).
	private static let minimumRowInsets: CGFloat = 36

	@MainActor
	private static func renderedLabelWidth(_ title: String, pane: SettingsPane, fontSize: CGFloat) -> CGFloat {
		let label = Label(title, systemImage: pane.systemImage).font(.system(size: fontSize)).fixedSize()
		return NSHostingView(rootView: label).fittingSize.width
	}

	/// The tab bar pushed French and Spanish tabs into a disabled overflow menu; the sidebar must
	/// instead fit every row as SwiftUI actually lays it out, icon included, in every language.
	@MainActor
	@Test(arguments: [1, 2, 3])
	func sidebarFitsEveryRenderedRowInEveryLanguage(sizeMode: Int) throws {
		let fontSize = SettingsLayout.sidebarFontSize(sizeMode: sizeMode)
		for language in Self.shippedLanguages {
			let bundle = try Self.bundle(for: language)
			let sidebar = SettingsLayout.paneSidebarWidth(sizeMode: sizeMode, bundle: bundle)
			for pane in SettingsPane.allCases {
				let title = pane.title(bundle: bundle)
				let row = Self.renderedLabelWidth(title, pane: pane, fontSize: fontSize)
				#expect(row > 0, "\(language): \(title)")
				#expect(
					row + Self.minimumRowInsets <= sidebar,
					"\(language) size \(sizeMode): \(title) needs \(row) + insets, sidebar is \(sidebar)")
			}
		}
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

	private static let screen = NSSize(width: 1440, height: 875)
	private static let minimum = NSSize(width: 798, height: 520)
	private static let ideal = NSSize(width: 958, height: 640)

	@Test func firstOpenGrowsToTheIdealSize() {
		// The Settings scene's own default: 900 wide, content at the minimum height.
		let sceneDefault = NSSize(width: 900, height: 524)
		#expect(
			SettingsLayout.openingContentSize(
				current: sceneDefault, minimum: Self.minimum, ideal: Self.ideal, available: Self.screen,
				alreadySized: false) == Self.ideal)
	}

	@Test func laterOpensKeepTheRestoredSize() {
		let restored = NSSize(width: 800, height: 530)
		#expect(
			SettingsLayout.openingContentSize(
				current: restored, minimum: Self.minimum, ideal: Self.ideal, available: Self.screen,
				alreadySized: true) == nil)
	}

	@Test func firstOpenNeverShrinksAWindowThatIsAlreadyLarger() {
		let large = NSSize(width: 1100, height: 600)
		#expect(
			SettingsLayout.openingContentSize(
				current: large, minimum: Self.minimum, ideal: Self.ideal, available: Self.screen,
				alreadySized: false) == NSSize(width: 1100, height: 640))
	}

	@Test func idealSizeIsCappedToTheScreenButNeverBelowTheMinimum() {
		#expect(
			SettingsLayout.openingContentSize(
				current: Self.minimum, minimum: Self.minimum, ideal: Self.ideal,
				available: NSSize(width: 900, height: 600), alreadySized: false) == NSSize(width: 900, height: 600))
		#expect(
			SettingsLayout.openingContentSize(
				current: Self.minimum, minimum: Self.minimum, ideal: Self.ideal,
				available: NSSize(width: 700, height: 400), alreadySized: false) == nil)
	}

	@Test func everyLanguageOpensAtItsOwnIdealWidth() throws {
		for language in Self.shippedLanguages {
			let sidebar = SettingsLayout.paneSidebarWidth(sizeMode: 3, bundle: try Self.bundle(for: language))
			let minimum = NSSize(
				width: SettingsLayout.minimumWindowWidth(sidebarWidth: sidebar), height: SettingsLayout.minimumHeight)
			let ideal = NSSize(
				width: SettingsLayout.idealWindowWidth(sidebarWidth: sidebar), height: SettingsLayout.idealHeight)
			let opened = try #require(
				SettingsLayout.openingContentSize(
					current: minimum, minimum: minimum, ideal: ideal, available: Self.screen, alreadySized: false),
				"\(language)")
			#expect(opened.width == sidebar + SettingsLayout.idealDetailWidth, "\(language)")
			#expect(opened.height == SettingsLayout.idealHeight, "\(language)")
		}
	}
}
