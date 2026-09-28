import AppKit
import Foundation
import Testing

@testable import Whispera

struct SkipSilenceNoticeTests {
	@Test func skippedClipNoticeNamesTheSetting() {
		#expect(VoiceActivitySettings.noSpeechNotice.contains("Skip Silence"))
	}
}
