import Carbon
import Foundation

class KeyboardInputSourceManager {
	static let shared = KeyboardInputSourceManager()
	private let logger = AppLogger.shared.general

	private init() {}

	func getCurrentKeyboardLanguageCode() -> String? {
		guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
			logger.info("Failed to get current keyboard input source")
			return nil
		}

		guard let sourceID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
			logger.info("Failed to get input source ID")
			return nil
		}

		let identifier = Unmanaged<CFString>.fromOpaque(sourceID).takeUnretainedValue() as String
		logger.info("Current keyboard input source identifier: '\(identifier)'")

		let languageCode = Constants.languageCodeFromKeyboardIdentifier(identifier)

		if let code = languageCode {
			let languageName = Constants.languageName(for: code)
			logger.info("Mapped to language code: '\(code)' (\(languageName))")
		} else {
			logger.info("No mapping found for identifier '\(identifier)' - will fallback to English")
		}

		return languageCode
	}

	func getLanguageForRecording(autoDetectEnabled: Bool, manualLanguage: String) -> String {
		guard autoDetectEnabled else {
			logger.info("Auto-detect disabled, using manual language: \(manualLanguage)")
			return manualLanguage
		}

		guard let detectedCode = getCurrentKeyboardLanguageCode() else {
			logger.info("Could not detect keyboard language, falling back to English")
			return Constants.defaultLanguageName
		}

		let languageName = Constants.languageName(for: detectedCode)
		logger.info("Auto-detected language for recording: \(languageName) (\(detectedCode))")

		return languageName
	}
}
