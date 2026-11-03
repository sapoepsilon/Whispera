import Foundation
import Testing

@testable import Whispera

struct AutostartDictationAffordanceTests {
	private let key = AutostartDictationAffordance.environmentKey

	@Test func offWithoutTheVariable() {
		#expect(AutostartDictationAffordance.requestedSeconds(environment: [:]) == nil)
	}

	@Test func ignoresUnparseableOrNonPositiveValues() {
		for value in ["", "yes", "0", "-3", "nan"] {
			#expect(AutostartDictationAffordance.requestedSeconds(environment: [key: value]) == nil)
		}
	}

	#if DEBUG
		@Test func debugBuildsReadAndClampTheDuration() {
			#expect(AutostartDictationAffordance.requestedSeconds(environment: [key: "5"]) == 5)
			#expect(
				AutostartDictationAffordance.requestedSeconds(environment: [key: "9999"])
					== AutostartDictationAffordance.maximumSeconds)
		}
	#else
		@Test func releaseBuildsNeverReadTheVariable() {
			#expect(AutostartDictationAffordance.requestedSeconds(environment: [key: "5"]) == nil)
		}
	#endif
}
