import AppKit
import Foundation
import Testing

@testable import Whispera

struct RecordingOverlayTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "RecordingOverlayTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsKeepTheExistingPillAtTheBottom() {
		let defaults = isolatedDefaults()
		#expect(RecordingOverlayStyle.stored(in: defaults) == .pill)
		#expect(RecordingOverlayPosition.stored(in: defaults) == .bottom)
	}

	@Test func storedValuesRoundTrip() {
		let defaults = isolatedDefaults()
		defaults.set(RecordingOverlayStyle.minimal.rawValue, forKey: RecordingOverlayStyle.defaultsKey)
		defaults.set(RecordingOverlayPosition.top.rawValue, forKey: RecordingOverlayPosition.defaultsKey)
		#expect(RecordingOverlayStyle.stored(in: defaults) == .minimal)
		#expect(RecordingOverlayPosition.stored(in: defaults) == .top)
	}

	@Test(arguments: [AudioState.initializing, .recording, .transcribing])
	func exactlyOneSurfacePerStyleWhileActiveInTextMode(state: AudioState) {
		#expect(RecordingOverlayPolicy.shouldShowPill(state: state, mode: .text, style: .pill))
		#expect(!RecordingOverlayPolicy.shouldShowMinimalIndicator(state: state, mode: .text, style: .pill))

		#expect(!RecordingOverlayPolicy.shouldShowPill(state: state, mode: .text, style: .minimal))
		#expect(RecordingOverlayPolicy.shouldShowMinimalIndicator(state: state, mode: .text, style: .minimal))

		#expect(!RecordingOverlayPolicy.shouldShowPill(state: state, mode: .text, style: .none))
		#expect(!RecordingOverlayPolicy.shouldShowMinimalIndicator(state: state, mode: .text, style: .none))
	}

	@Test(arguments: RecordingOverlayStyle.allCases)
	func nothingShowsWhenIdleOrInLiveMode(style: RecordingOverlayStyle) {
		#expect(!RecordingOverlayPolicy.shouldShowPill(state: .idle, mode: .text, style: style))
		#expect(!RecordingOverlayPolicy.shouldShowMinimalIndicator(state: .idle, mode: .text, style: style))
		#expect(!RecordingOverlayPolicy.shouldShowPill(state: .recording, mode: .liveTranscription, style: style))
		#expect(
			!RecordingOverlayPolicy.shouldShowMinimalIndicator(
				state: .recording, mode: .liveTranscription, style: style))
	}

	@Test func bottomOriginMatchesLegacyPlacement() {
		let visible = NSRect(x: 0, y: 25, width: 1000, height: 800)
		let size = NSSize(width: 200, height: 100)
		let origin = RecordingOverlayPolicy.origin(for: size, in: visible, position: .bottom)
		#expect(origin == NSPoint(x: 400, y: 25 + 80))
	}

	@Test func topOriginMirrorsBottomInset() {
		let visible = NSRect(x: 100, y: 0, width: 1000, height: 800)
		let size = NSSize(width: 200, height: 100)
		let origin = RecordingOverlayPolicy.origin(for: size, in: visible, position: .top)
		#expect(origin == NSPoint(x: 500, y: 800 - 80 - 100))
	}
}
