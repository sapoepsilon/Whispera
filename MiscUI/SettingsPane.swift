import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
	case general
	case servers
	case account
	case recipes
	case textInsertion
	case storage
	case liveTranscription
	case fileTranscription
	case history
	case automation
	case benchmark
	case debug

	var id: String { rawValue }

	func title(bundle: Bundle = .main) -> String {
		switch self {
		case .general: return String(localized: "General", bundle: bundle)
		case .servers: return String(localized: "Servers", bundle: bundle)
		case .account: return String(localized: "Account", bundle: bundle)
		case .recipes: return String(localized: "Recipes", bundle: bundle)
		case .textInsertion: return String(localized: "Text Insertion", bundle: bundle)
		case .storage: return String(localized: "Storage & Downloads", bundle: bundle)
		case .liveTranscription: return String(localized: "Live Transcription", bundle: bundle)
		case .fileTranscription: return String(localized: "File Transcription", bundle: bundle)
		case .history: return String(localized: "History", bundle: bundle)
		case .automation: return String(localized: "Automation", bundle: bundle)
		case .benchmark: return String(localized: "Benchmark", bundle: bundle)
		case .debug: return String(localized: "Debug", bundle: bundle)
		}
	}

	var systemImage: String {
		switch self {
		case .general: return "gear"
		case .servers: return "server.rack"
		case .account: return "person.crop.circle"
		case .recipes: return "command"
		case .textInsertion: return "text.cursor"
		case .storage: return "internaldrive"
		case .liveTranscription: return "waveform"
		case .fileTranscription: return "doc.on.doc"
		case .history: return "clock.arrow.circlepath"
		case .automation: return "bolt.horizontal"
		case .benchmark: return "speedometer"
		case .debug: return "ladybug"
		}
	}

	var accessibilityIdentifier: String { "settingsSidebar.\(rawValue)" }

	var sidebarGroup: Int {
		switch self {
		case .general, .servers, .account: return 0
		case .recipes, .textInsertion, .liveTranscription, .fileTranscription, .history: return 1
		case .storage, .automation, .benchmark, .debug: return 2
		}
	}

	var iconColor: Color {
		switch self {
		case .general, .debug: return .gray
		case .servers, .fileTranscription: return .blue
		case .account, .recipes: return .purple
		case .textInsertion: return .indigo
		case .storage, .automation: return .orange
		case .liveTranscription: return .red
		case .history: return .green
		case .benchmark: return .pink
		}
	}

	func matches(_ query: String) -> Bool {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return true }
		let keywords: [String] =
			switch self {
			case .general:
				[
					"Microphone", "Whisper Model", "Recording Control", "Shortcuts & Feedback", "Appearance",
					"Application", "Language",
				]
			case .servers: ["Speech", "LLM server", "Mac Link"]
			case .account: ["Sign in", "Devices"]
			case .recipes: ["Clean up", "Shortcut"]
			case .textInsertion: ["Clipboard", "Auto-Submit"]
			case .storage: ["WhisperKit Models", "Application Logs"]
			case .liveTranscription: ["Live Transcription Mode"]
			case .fileTranscription: ["YouTube", "Transcription Options"]
			case .history: ["Save transcription history", "Save recordings"]
			case .automation: ["Remote Control", "Launchers", "Command Line"]
			case .benchmark: ["RTF Benchmark"]
			case .debug: ["Logging"]
			}
		return ([title()] + keywords.map { NSLocalizedString($0, comment: "") })
			.contains { $0.localizedStandardContains(query) }
	}

	/// Post-Processing became the Clean up recipe, so a request for its old pane
	/// (a saved destination, an automation link) opens Recipes.
	static func named(_ raw: String) -> SettingsPane? {
		raw == "postProcessing" ? .recipes : SettingsPane(rawValue: raw)
	}

	/// Live Transcription and Automation are not supported for regular users yet, so they sit
	/// behind Debug Mode with the Debug pane. The features themselves keep working (URL scheme,
	/// App Intents, CLI); only their settings are hidden.
	static func visible(debugModeEnabled: Bool) -> [SettingsPane] {
		allCases.filter { pane in
			switch pane {
			case .liveTranscription, .automation, .debug: return debugModeEnabled
			default: return true
			}
		}
	}

	/// A pane that was hidden while selected (Debug Mode turned off) falls back to
	/// General instead of leaving the detail column empty.
	static func resolve(_ selection: SettingsPane?, visible: [SettingsPane]) -> SettingsPane {
		guard let selection, visible.contains(selection) else { return .general }
		return selection
	}

	/// Panes stay mounted once opened so switching rows keeps their in-progress state (a running
	/// benchmark, a History search, an unsaved API key), as the old tab view did. Unopened panes
	/// are not built, and a pane that gets hidden is dropped until it is opened again.
	static func mounted(opened: Set<SettingsPane>, current: SettingsPane, visible: [SettingsPane]) -> [SettingsPane] {
		visible.filter { $0 == current || opened.contains($0) }
	}
}

/// The sidebar has a fixed width that fits the longest visible row label in the current language, so
/// French and Spanish rows are never truncated; the detail column keeps the room the panes had.
enum SettingsLayout {
	static let minimumSidebarWidth: CGFloat = 200
	/// Icon, the space after it, the selection highlight insets and the column's own padding.
	static let sidebarRowChrome: CGFloat = 76
	static let minimumDetailWidth: CGFloat = 520
	static let idealDetailWidth: CGFloat = 680
	static let minimumHeight: CGFloat = 520
	static let idealHeight: CGFloat = 640

	/// Sidebar rows follow the "Sidebar icon size" choice in System Settings > Appearance, which
	/// macOS stores as the table size mode (1 small, 2 medium, 3 large).
	static func sidebarFontSize(sizeMode: Int) -> CGFloat {
		switch sizeMode {
		case 1: return 11
		case 3: return 15
		default: return 13
		}
	}

	static let sidebarSizeModeKey = "NSTableViewDefaultSizeMode"

	static func sidebarFont(sizeMode: Int) -> NSFont {
		.systemFont(ofSize: sidebarFontSize(sizeMode: sizeMode))
	}

	static func sidebarWidth(forTitles titles: [String], font: NSFont) -> CGFloat {
		let widest = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
		return max(minimumSidebarWidth, widest + sidebarRowChrome)
	}

	/// Only the visible rows are measured, so a hidden pane's long label does not widen the window
	/// for everyone.
	static func paneSidebarWidth(sizeMode: Int, panes: [SettingsPane], bundle: Bundle = .main) -> CGFloat {
		sidebarWidth(forTitles: panes.map { $0.title(bundle: bundle) }, font: sidebarFont(sizeMode: sizeMode))
	}

	static var currentSizeMode: Int {
		UserDefaults.standard.integer(forKey: sidebarSizeModeKey)
	}

	static func minimumWindowWidth(sidebarWidth: CGFloat) -> CGFloat {
		sidebarWidth + minimumDetailWidth
	}

	static func idealWindowWidth(sidebarWidth: CGFloat) -> CGFloat {
		sidebarWidth + idealDetailWidth
	}

	static func size(_ size: NSSize, atLeast minimum: NSSize) -> NSSize {
		NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
	}

	/// The Settings scene ignores the content's ideal size and opens at a fixed default that is
	/// too short for the panes. The first time the sidebar layout opens, the window grows to the
	/// ideal size, capped to the screen; after that the frame SwiftUI restores is the user's size.
	static func openingContentSize(
		current: NSSize, minimum: NSSize, ideal: NSSize, available: NSSize, alreadySized: Bool
	) -> NSSize? {
		guard !alreadySized else { return nil }
		let target = NSSize(
			width: max(current.width, minimum.width, min(ideal.width, available.width)),
			height: max(current.height, minimum.height, min(ideal.height, available.height)))
		return target == current ? nil : target
	}

	/// The grown frame keeps the window's top edge and horizontal center where it fits. The
	/// window's own constraint only keeps the title bar on screen, so a window that grows past
	/// the bottom of a short screen is moved up here.
	static func openingFrame(from frame: NSRect, size: NSSize, visible: NSRect) -> NSRect {
		func clamp(_ origin: CGFloat, length: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
			max(lower, min(origin, upper - length))
		}
		let x = clamp(frame.midX - size.width / 2, length: size.width, min: visible.minX, max: visible.maxX)
		let y = clamp(frame.maxY - size.height, length: size.height, min: visible.minY, max: visible.maxY)
		return NSRect(x: x, y: y, width: size.width, height: size.height)
	}

	static let sizedToIdealKey = "settingsWindowSizedToIdeal"
}
