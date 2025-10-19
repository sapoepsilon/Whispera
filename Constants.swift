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
        "mandarin": "zh"
    ]
    
    public static let defaultLanguageCode = "en"
    public static let defaultLanguageName = "english"
    
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
        return languages.first { $0.value == languageCode }?.key.capitalized ?? defaultLanguageName.capitalized
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
        "com.apple.inputmethod.Vietnamese.VietnameseIM": "vi"
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
