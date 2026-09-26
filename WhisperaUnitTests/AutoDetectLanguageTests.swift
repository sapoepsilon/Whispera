import Foundation
import Testing

@testable import Whispera

struct AutoDetectLanguageTests {
	@Test func autoLanguageConstants() {
		#expect(Constants.decodingLanguageCode(for: Constants.autoDetectLanguageName) == nil)
		#expect(Constants.decodingLanguageCode(for: "Auto") == nil)
		#expect(Constants.decodingLanguageCode(for: "german") == "de")
		#expect(Constants.isAutoDetectLanguage("auto"))
		#expect(!Constants.isAutoDetectLanguage("english"))
	}
}
