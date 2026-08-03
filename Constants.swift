import AppKit
import Foundation
import SwiftUI

enum MaterialStyle: String, CaseIterable, Identifiable {
	case ultraThin = "Ultra Thin"
	case thin = "Thin"
	case regular = "Regular"
	case thick = "Thick"
	case ultraThick = "Ultra Thick"

	var id: String { rawValue }

	var material: Material {
		switch self {
		case .ultraThin: return .ultraThinMaterial
		case .thin: return .thinMaterial
		case .regular: return .regularMaterial
		case .thick: return .thickMaterial
		case .ultraThick: return .ultraThickMaterial
		}
	}

	static var `default`: MaterialStyle { .thin }
}

//enum GlassStyle: String, CaseIterable, Identifiable {
//
//	var glass: Glass {
//		switch self {
//			case .
//		}
//	}
//}

/// The app's whole motion vocabulary. Every animated surface (menu bar popover,
/// listening pill, controls panel) reads these four curves instead of spelling
/// out its own literals, so the surfaces cannot drift apart when one is tuned.
///
/// Reduce Motion is deliberately NOT baked in here: call sites pass
/// `reduceMotion ? nil : Motion.<curve>` so the gate stays visible in the view.
enum Motion {
	/// A size-affecting module entered or left; siblings glide to their new place.
	static let structural: Animation = .easeOut(duration: structuralDuration)
	/// Content blooming in while an animated frame growth uncovers it.
	static let reveal: Animation = .easeOut(duration: revealDuration)
	/// Transient overlays (toasts) that need a little settle on the way in.
	static let transient: Animation = .spring(response: 0.4, dampingFraction: 0.8)
	/// Button press feedback.
	static let press: Animation = .easeOut(duration: pressDuration)

	/// Status-icon glyph swap: the outgoing symbol scales and fades out while the
	/// incoming one scales in. Its own beat, distinct from the four above.
	static let iconMorph: Animation = .spring(duration: iconMorphDuration)
	/// The tint change that rides along with `iconMorph`, on the same beat.
	static let iconMorphTint: Animation = .easeInOut(duration: iconMorphDuration)

	/// Per-bar level tracking in the audio meter. Deliberately quick and loose:
	/// it follows a continuous signal rather than a layout change.
	static let meter: Animation = .spring(response: 0.15, dampingFraction: 0.6)

	static let pressScale: CGFloat = 0.98
	static let pressOpacity: Double = 0.8

	// AppKit mirrors. NSAnimationContext takes raw seconds and `Animation` has no
	// public duration accessor, so the numbers live here and the SwiftUI curves
	// above are built from them - one place to change, two consumers.
	static let structuralDuration: TimeInterval = 0.25
	static let revealDuration: TimeInterval = 0.22
	static let pressDuration: TimeInterval = 0.1
	/// Shared by `iconMorph` and `iconMorphTint` so the glyph and its tint can
	/// never fall out of step.
	static let iconMorphDuration: TimeInterval = 0.3

	/// AppKit-side Reduce Motion, for windows that animate their own frame.
	@MainActor static var systemReduceMotion: Bool {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}
}

struct Constants {
	public static let languages: [String: String] = [
		"english": "en",
		"chinese": "zh",
		"german": "de",
		"spanish": "es",
		"russian": "ru",
		"korean": "ko",
		"french": "fr",
		"japanese": "ja",
		"portuguese": "pt",
		"turkish": "tr",
		"polish": "pl",
		"catalan": "ca",
		"dutch": "nl",
		"arabic": "ar",
		"swedish": "sv",
		"italian": "it",
		"indonesian": "id",
		"hindi": "hi",
		"finnish": "fi",
		"vietnamese": "vi",
		"hebrew": "he",
		"ukrainian": "uk",
		"greek": "el",
		"malay": "ms",
		"czech": "cs",
		"romanian": "ro",
		"danish": "da",
		"hungarian": "hu",
		"tamil": "ta",
		"norwegian": "no",
		"thai": "th",
		"urdu": "ur",
		"croatian": "hr",
		"bulgarian": "bg",
		"lithuanian": "lt",
		"latin": "la",
		"maori": "mi",
		"malayalam": "ml",
		"welsh": "cy",
		"slovak": "sk",
		"telugu": "te",
		"persian": "fa",
		"latvian": "lv",
		"bengali": "bn",
		"serbian": "sr",
		"azerbaijani": "az",
		"slovenian": "sl",
		"kannada": "kn",
		"estonian": "et",
		"macedonian": "mk",
		"breton": "br",
		"basque": "eu",
		"icelandic": "is",
		"armenian": "hy",
		"nepali": "ne",
		"mongolian": "mn",
		"bosnian": "bs",
		"kazakh": "kk",
		"albanian": "sq",
		"swahili": "sw",
		"galician": "gl",
		"marathi": "mr",
		"punjabi": "pa",
		"sinhala": "si",
		"khmer": "km",
		"shona": "sn",
		"yoruba": "yo",
		"somali": "so",
		"afrikaans": "af",
		"occitan": "oc",
		"georgian": "ka",
		"belarusian": "be",
		"tajik": "tg",
		"sindhi": "sd",
		"gujarati": "gu",
		"amharic": "am",
		"yiddish": "yi",
		"lao": "lo",
		"uzbek": "uz",
		"faroese": "fo",
		"haitian creole": "ht",
		"pashto": "ps",
		"turkmen": "tk",
		"nynorsk": "nn",
		"maltese": "mt",
		"sanskrit": "sa",
		"luxembourgish": "lb",
		"myanmar": "my",
		"tibetan": "bo",
		"tagalog": "tl",
		"malagasy": "mg",
		"assamese": "as",
		"tatar": "tt",
		"hawaiian": "haw",
		"lingala": "ln",
		"hausa": "ha",
		"bashkir": "ba",
		"javanese": "jw",
		"sundanese": "su",
		"cantonese": "yue",
		"burmese": "my",
		"valencian": "ca",
		"flemish": "nl",
		"haitian": "ht",
		"letzeburgesch": "lb",
		"pushto": "ps",
		"panjabi": "pa",
		"moldavian": "ro",
		"moldovan": "ro",
		"sinhalese": "si",
		"castilian": "es",
		"mandarin": "zh",
	]

	public static let defaultLanguageCode = "en"
	public static let defaultLanguageName = "english"
	// Shared by every @AppStorage("enableStreaming") fallback and the first-launch
	// defaults: divergent inline copies of this literal caused duplicate recording windows.
	public static let enableStreamingDefault = false

	// Helper to get sorted language names for UI
	public static var sortedLanguageNames: [String] {
		return Array(languages.keys).sorted()
	}

	// Helper to get language code from name
	public static func languageCode(for languageName: String) -> String {
		return languages[languageName.lowercased()] ?? defaultLanguageCode
	}

	// Helper to get language name from code
	public static func languageName(for languageCode: String) -> String {
		return languages.first { $0.value == languageCode }?.key.capitalized
			?? defaultLanguageName.capitalized
	}

	private static let keyboardIdentifierToLanguageCode: [String: String] = [
		"com.apple.keylayout.US": "en",
		"com.apple.keylayout.ABC": "en",
		"com.apple.keylayout.USInternational-PC": "en",
		"com.apple.keylayout.British": "en",
		"com.apple.keylayout.Australian": "en",
		"com.apple.keylayout.Canadian": "en",
		"com.apple.keylayout.Russian": "ru",
		"com.apple.keylayout.RussianWin": "ru",
		"com.apple.keylayout.Russian-Phonetic": "ru",
		"com.apple.keylayout.Spanish": "es",
		"com.apple.keylayout.Spanish-ISO": "es",
		"com.apple.keylayout.German": "de",
		"com.apple.keylayout.French": "fr",
		"com.apple.keylayout.French-PC": "fr",
		"com.apple.keylayout.Italian": "it",
		"com.apple.keylayout.Portuguese": "pt",
		"com.apple.keylayout.PortugueseBrazilian": "pt",
		"com.apple.keylayout.Dutch": "nl",
		"com.apple.keylayout.Swedish": "sv",
		"com.apple.keylayout.Norwegian": "no",
		"com.apple.keylayout.Danish": "da",
		"com.apple.keylayout.Finnish": "fi",
		"com.apple.keylayout.Polish": "pl",
		"com.apple.keylayout.PolishPro": "pl",
		"com.apple.keylayout.Czech": "cs",
		"com.apple.keylayout.Hungarian": "hu",
		"com.apple.keylayout.Romanian": "ro",
		"com.apple.keylayout.Turkish": "tr",
		"com.apple.keylayout.Greek": "el",
		"com.apple.keylayout.Hebrew": "he",
		"com.apple.keylayout.Arabic": "ar",
		"com.apple.keylayout.Korean": "ko",
		"com.apple.keylayout.Japanese": "ja",
		"com.apple.keylayout.Chinese-Simplified": "zh",
		"com.apple.keylayout.PinyinKeyboard": "zh",
		"com.apple.keylayout.Chinese-Traditional": "zh",
		"com.apple.keylayout.Ukrainian": "uk",
		"com.apple.keylayout.Croatian": "hr",
		"com.apple.keylayout.Serbian": "sr",
		"com.apple.keylayout.Bulgarian": "bg",
		"com.apple.keylayout.Catalan": "ca",
		"com.apple.keylayout.Icelandic": "is",
		"com.apple.inputmethod.Korean.2SetKorean": "ko",
		"com.apple.inputmethod.SCIM.ITABC": "zh",
		"com.apple.inputmethod.TCIM.Cangjie": "zh",
		"com.apple.inputmethod.TYIM.Hiragana": "ja",
		"com.apple.inputmethod.TYIM.Katakana": "ja",
		"com.apple.inputmethod.Vietnamese.VietnameseIM": "vi",
	]

	public static func languageCodeFromKeyboardIdentifier(_ identifier: String) -> String? {
		if let directMatch = keyboardIdentifierToLanguageCode[identifier] {
			return directMatch
		}

		for (key, value) in keyboardIdentifierToLanguageCode {
			if identifier.contains(key) || key.contains(identifier) {
				return value
			}
		}

		return nil
	}
}

extension MaterialStyle {
	init(rawValue: String) {
		switch rawValue {
		case "Ultra Thin": self = .ultraThin
		case "Thin": self = .thin
		case "Regular": self = .regular
		case "Thick": self = .thick
		case "Ultra Thick": self = .ultraThick
		default: self = .thin
		}
	}
}
