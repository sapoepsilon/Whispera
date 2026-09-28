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

	@Test func debugModeShowsEveryPaneInTheOldTabOrder() {
		#expect(
			SettingsPane.visible(debugModeEnabled: true) == [
				.general, .textInsertion, .storage, .liveTranscription, .fileTranscription, .history, .automation,
				.benchmark, .postProcessing, .debug,
			])
	}

	@Test func regularUsersOnlySeeTheSupportedPanes() {
		#expect(
			SettingsPane.visible(debugModeEnabled: false) == [
				.general, .textInsertion, .storage, .fileTranscription, .history, .benchmark, .postProcessing,
			])
	}

	@Test func debugAutomationAndLiveTranscriptionOnlyAppearInDebugMode() {
		let regular = SettingsPane.visible(debugModeEnabled: false)
		let debug = SettingsPane.visible(debugModeEnabled: true)
		for pane in [SettingsPane.debug, .automation, .liveTranscription] {
			#expect(!regular.contains(pane), "\(pane)")
			#expect(debug.contains(pane), "\(pane)")
		}
		#expect(regular.contains(.postProcessing))
	}

	@Test func hiddenSelectionFallsBackToGeneral() {
		let visible = SettingsPane.visible(debugModeEnabled: false)
		#expect(SettingsPane.resolve(.debug, visible: visible) == .general)
		#expect(SettingsPane.resolve(.liveTranscription, visible: visible) == .general)
		#expect(SettingsPane.resolve(.automation, visible: visible) == .general)
		#expect(SettingsPane.resolve(nil, visible: visible) == .general)
		#expect(SettingsPane.resolve(.history, visible: visible) == .history)
	}

	@Test func openedPanesStayMountedUntilHidden() {
		let all = SettingsPane.visible(debugModeEnabled: true)
		#expect(SettingsPane.mounted(opened: [], current: .general, visible: all) == [.general])
		#expect(
			SettingsPane.mounted(opened: [.general, .benchmark], current: .history, visible: all) == [
				.general, .history, .benchmark,
			])
		let withoutDebug = SettingsPane.visible(debugModeEnabled: false)
		#expect(
			SettingsPane.mounted(opened: [.general, .debug, .automation], current: .general, visible: withoutDebug)
				== [.general])
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
			for debugMode in [false, true] {
				let panes = SettingsPane.visible(debugModeEnabled: debugMode)
				let sidebar = SettingsLayout.paneSidebarWidth(sizeMode: sizeMode, panes: panes, bundle: bundle)
				for pane in panes {
					let title = pane.title(bundle: bundle)
					let row = Self.renderedLabelWidth(title, pane: pane, fontSize: fontSize)
					#expect(row > 0, "\(language): \(title)")
					#expect(
						row + Self.minimumRowInsets <= sidebar,
						"\(language) size \(sizeMode) debug \(debugMode): \(title) needs \(row) + insets, sidebar is \(sidebar)"
					)
				}
			}
		}
	}

	/// A hidden pane's label must not size the window for users who never see that row.
	@Test func sidebarWidthIgnoresHiddenPanes() throws {
		for language in Self.shippedLanguages {
			let bundle = try Self.bundle(for: language)
			let regular = SettingsPane.visible(debugModeEnabled: false)
			let font = SettingsLayout.sidebarFont(sizeMode: 2)
			#expect(
				SettingsLayout.paneSidebarWidth(sizeMode: 2, panes: regular, bundle: bundle)
					== SettingsLayout.sidebarWidth(forTitles: regular.map { $0.title(bundle: bundle) }, font: font),
				"\(language)")
			#expect(
				SettingsLayout.paneSidebarWidth(sizeMode: 2, panes: regular, bundle: bundle)
					<= SettingsLayout.paneSidebarWidth(
						sizeMode: 2, panes: SettingsPane.visible(debugModeEnabled: true), bundle: bundle),
				"\(language)")
		}
		let font = SettingsLayout.sidebarFont(sizeMode: 2)
		let long = String(repeating: "W", count: 60)
		#expect(
			SettingsLayout.sidebarWidth(forTitles: ["General", long], font: font)
				> SettingsLayout.sidebarWidth(forTitles: ["General"], font: font))
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

	@Test func grownWindowKeepsItsTopWhenItFits() {
		let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
		let frame = NSRect(x: 270, y: 300, width: 900, height: 552)
		#expect(
			SettingsLayout.openingFrame(from: frame, size: NSSize(width: 958, height: 668), visible: visible)
				== NSRect(x: 241, y: 184, width: 958, height: 668))
	}

	@Test func grownWindowMovesUpInsteadOfHangingOffTheBottomOfAShortScreen() {
		// A 1133x744 display: the scene opened the window 127 pt below the top of the screen
		let visible = NSRect(x: 0, y: 0, width: 1133, height: 719)
		let frame = NSRect(x: 114, y: 65, width: 904, height: 552)
		let grown = SettingsLayout.openingFrame(from: frame, size: NSSize(width: 904, height: 672), visible: visible)
		#expect(grown.size == NSSize(width: 904, height: 672))
		#expect(grown.minY == visible.minY)
		#expect(visible.contains(grown))
	}

	@Test func grownWindowStaysOnTheScreenHorizontally() {
		let visible = NSRect(x: 1440, y: 0, width: 1000, height: 800)
		let frame = NSRect(x: 1450, y: 100, width: 600, height: 552)
		let grown = SettingsLayout.openingFrame(from: frame, size: NSSize(width: 958, height: 668), visible: visible)
		#expect(grown.minX == visible.minX)
		#expect(visible.contains(grown))
	}

	@Test func everyLanguageOpensAtItsOwnIdealWidth() throws {
		for language in Self.shippedLanguages {
			let sidebar = SettingsLayout.paneSidebarWidth(
				sizeMode: 3, panes: SettingsPane.visible(debugModeEnabled: false), bundle: try Self.bundle(for: language))
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
