import SwiftUI
import Testing

@testable import Whispera

struct RecordingGlowColorTests {

	@Test func hexRoundTripsThroughColor() {
		let hex = "3AF2C8"
		#expect(RecordingGlowColor.hex(from: RecordingGlowColor.color(fromHex: hex)) == hex)
	}

	@Test func defaultHexRoundTrips() {
		let color = RecordingGlowColor.color(fromHex: RecordingGlowColor.defaultHex)
		#expect(RecordingGlowColor.hex(from: color) == RecordingGlowColor.defaultHex)
	}

	@Test(arguments: ["", "nope", "12345", "GGGGGG"])
	func invalidHexFallsBackToDefault(invalid: String) {
		let color = RecordingGlowColor.color(fromHex: invalid)
		#expect(RecordingGlowColor.hex(from: color) == RecordingGlowColor.defaultHex)
	}
}
