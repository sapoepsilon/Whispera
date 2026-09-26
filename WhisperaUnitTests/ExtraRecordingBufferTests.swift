import Foundation
import Testing

@testable import Whispera

struct ExtraRecordingBufferTests {
	private func makeDefaults() -> UserDefaults {
		UserDefaults(suiteName: "ExtraRecordingBufferTests.\(UUID().uuidString)")!
	}

	@Test func defaultsToNoTail() {
		#expect(RecordingControlSettings(defaults: makeDefaults()).extraRecordingBuffer == 0)
	}

	@Test func convertsMillisecondsToSeconds() {
		let defaults = makeDefaults()
		defaults.set(250, forKey: RecordingControlSettings.Key.extraRecordingBufferMs)
		#expect(RecordingControlSettings(defaults: defaults).extraRecordingBuffer == 0.25)
	}

	@Test(arguments: [(-100, 0.0), (0, 0.0), (500, 0.5), (2000, 0.5)])
	func clampsToSupportedRange(stored: Int, expected: TimeInterval) {
		let defaults = makeDefaults()
		defaults.set(stored, forKey: RecordingControlSettings.Key.extraRecordingBufferMs)
		#expect(RecordingControlSettings(defaults: defaults).extraRecordingBuffer == expected)
	}
}
