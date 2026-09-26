import AppKit
import SwiftUI

enum RecordingOverlayStyle: String, CaseIterable, Identifiable {
	case pill
	case minimal
	case none

	static let defaultsKey = "recordingOverlayStyle"

	var id: String { rawValue }

	var displayName: LocalizedStringKey {
		switch self {
		case .pill: return "Pill"
		case .minimal: return "Minimal"
		case .none: return "None"
		}
	}

	static func stored(in defaults: UserDefaults = .standard) -> RecordingOverlayStyle {
		defaults.string(forKey: defaultsKey).flatMap(RecordingOverlayStyle.init(rawValue:)) ?? .pill
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
		style == .pill && RecordingWindowPolicy.shouldShowListeningWindow(state: state, mode: mode)
	}

	static func shouldShowMinimalIndicator(
		state: AudioState, mode: RecordingMode, style: RecordingOverlayStyle
	) -> Bool {
		style == .minimal && RecordingWindowPolicy.shouldShowListeningWindow(state: state, mode: mode)
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

@MainActor
final class MinimalRecordingIndicatorController {
	private let audioManager: AudioManager
	private let defaults: UserDefaults
	private let indicatorManager = RecordingIndicatorManager()
	private var stateObserver: NSObjectProtocol?
	private var isShowing = false

	init(audioManager: AudioManager, defaults: UserDefaults = .standard) {
		self.audioManager = audioManager
		self.defaults = defaults
		stateObserver = NotificationCenter.default.addObserver(
			forName: NSNotification.Name("RecordingStateChanged"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.update()
			}
		}
	}

	deinit {
		if let stateObserver {
			NotificationCenter.default.removeObserver(stateObserver)
		}
	}

	func update() {
		let shouldShow = RecordingOverlayPolicy.shouldShowMinimalIndicator(
			state: audioManager.currentState,
			mode: audioManager.currentRecordingMode,
			style: RecordingOverlayStyle.stored(in: defaults)
		)
		guard shouldShow != isShowing else { return }
		isShowing = shouldShow
		if shouldShow {
			indicatorManager.showIndicator(position: RecordingOverlayPosition.stored(in: defaults))
		} else {
			indicatorManager.hideIndicator()
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
			description: "What appears on screen while dictating"
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
