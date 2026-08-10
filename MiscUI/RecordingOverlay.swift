import AppKit
import SwiftUI

enum RecordingOverlayStyle: String, CaseIterable, Identifiable {
	case pill
	case none

	static let defaultsKey = "recordingOverlayStyle"

	var id: String { rawValue }

	var displayName: LocalizedStringKey {
		switch self {
		case .pill: return "Pill"
		case .none: return "None"
		}
	}

	static func stored(in defaults: UserDefaults = .standard) -> RecordingOverlayStyle {
		defaults.string(forKey: defaultsKey).flatMap(RecordingOverlayStyle.init(rawValue:)) ?? .pill
	}

	/// Settings binds the raw string, so a style that no longer exists (the removed "minimal")
	/// would leave the picker with nothing selected even though the pill shows.
	static func dropUnknownStoredValue(in defaults: UserDefaults) {
		guard let raw = defaults.string(forKey: defaultsKey), RecordingOverlayStyle(rawValue: raw) == nil
		else { return }
		defaults.removeObject(forKey: defaultsKey)
		AppLogger.shared.general.info("Recording overlay style \(raw) is no longer offered; using the pill")
	}
}

enum RecordingOverlayPosition: String, CaseIterable, Identifiable {
	case top
	case bottom

	static let defaultsKey = "recordingOverlayPosition"

	var id: String { rawValue }

	var displayName: LocalizedStringKey {
		switch self {
		case .top: return "Top"
		case .bottom: return "Bottom"
		}
	}

	static func stored(in defaults: UserDefaults = .standard) -> RecordingOverlayPosition {
		defaults.string(forKey: defaultsKey).flatMap(RecordingOverlayPosition.init(rawValue:))
			?? .bottom
	}
}

enum RecordingOverlayPolicy {
	static func shouldShowPill(state: AudioState, mode: RecordingMode, style: RecordingOverlayStyle)
		-> Bool
	{
		// Live mode shows its own words HUD instead of the pill
		style == .pill && mode != .liveTranscription
			&& RecordingWindowPolicy.shouldShowListeningWindow(state: state)
	}

	// The bottom inset matches the pill's historical placement at 10% of the visible height.
	static func origin(
		for windowSize: NSSize, in visibleFrame: NSRect, position: RecordingOverlayPosition
	) -> NSPoint {
		let x = visibleFrame.minX + (visibleFrame.width - windowSize.width) / 2
		let inset = visibleFrame.height * 0.1
		switch position {
		case .bottom:
			return NSPoint(x: x, y: visibleFrame.minY + inset)
		case .top:
			return NSPoint(x: x, y: visibleFrame.maxY - inset - windowSize.height)
		}
	}
}

struct RecordingOverlaySettingRows: View {
	@AppStorage(RecordingOverlayStyle.defaultsKey) private var styleRaw = RecordingOverlayStyle.pill
		.rawValue
	@AppStorage(RecordingOverlayPosition.defaultsKey) private var positionRaw =
		RecordingOverlayPosition.bottom.rawValue

	var body: some View {
		SettingRow(
			"Recording Overlay",
			description: "What appears on screen while dictating."
		) {
			Picker("", selection: $styleRaw) {
				ForEach(RecordingOverlayStyle.allCases) { style in
					Text(style.displayName).tag(style.rawValue)
				}
			}
			.labelsHidden()
			.pickerStyle(.segmented)
			.frame(width: 220)
		}

		if styleRaw != RecordingOverlayStyle.none.rawValue {
			SettingRow("Overlay Position") {
				Picker("", selection: $positionRaw) {
					ForEach(RecordingOverlayPosition.allCases) { position in
						Text(position.displayName).tag(position.rawValue)
					}
				}
				.labelsHidden()
				.pickerStyle(.segmented)
				.frame(width: 160)
			}
		}
	}
}
