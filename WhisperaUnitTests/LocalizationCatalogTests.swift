import Foundation
import Testing

@testable import Whispera

struct LocalizationCatalogTests {

	private static let shippedLanguages = ["es", "de", "fr"]

	private struct Catalog {
		let sourceLanguage: String
		/// key -> language -> translated value
		let translations: [String: [String: String]]
		let states: [String: [String: String]]
	}

	private static func loadCatalog() throws -> Catalog {
		let repoRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let url = repoRoot.appendingPathComponent("MiscUI/Localizable.xcstrings")
		let data = try Data(contentsOf: url)
		let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		let strings = try #require(json["strings"] as? [String: Any])
		var translations: [String: [String: String]] = [:]
		var states: [String: [String: String]] = [:]
		for (key, entry) in strings {
			let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
			for (language, localization) in localizations {
				let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
				translations[key, default: [:]][language] = unit?["value"] as? String
				states[key, default: [:]][language] = unit?["state"] as? String
			}
			if translations[key] == nil { translations[key] = [:] }
		}
		return Catalog(
			sourceLanguage: json["sourceLanguage"] as? String ?? "en",
			translations: translations,
			states: states)
	}

	/// Format specifiers without positional indexes, sorted, so reordered arguments still match.
	static func formatSpecifiers(in string: String) -> [String] {
		let pattern = #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|llu|ld|lu|lf|hhd|hd|d|i|u|f|e|g|x|X|@|c|s)"#
		let regex = try! NSRegularExpression(pattern: pattern)
		let range = NSRange(string.startIndex..., in: string)
		return regex.matches(in: string, range: range)
			.compactMap { Range($0.range, in: string).map { String(string[$0]) } }
			.map { $0.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }
			.sorted()
	}

	@Test func catalogHasASourceLanguageOfEnglish() throws {
		#expect(try Self.loadCatalog().sourceLanguage == "en")
	}

	@Test func everyKeyIsTranslatedIntoEveryShippedLanguage() throws {
		let catalog = try Self.loadCatalog()
		#expect(catalog.translations.count > 400)
		for (key, values) in catalog.translations {
			for language in Self.shippedLanguages {
				let value = values[language] ?? ""
				#expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) has no \(language) text")
				#expect(
					catalog.states[key]?[language] == "translated", "\(key) is not translated in \(language)")
			}
		}
	}

	@Test func translationsKeepTheKeysFormatSpecifiers() throws {
		let catalog = try Self.loadCatalog()
		for (key, values) in catalog.translations {
			let expected = Self.formatSpecifiers(in: key)
			for language in Self.shippedLanguages {
				guard let value = values[language] else { continue }
				#expect(
					Self.formatSpecifiers(in: value) == expected,
					"\(language) translation of \"\(key)\" changes its format specifiers: \"\(value)\"")
			}
		}
	}

	@Test func formatSpecifierParsingHandlesPositionalArguments() {
		#expect(Self.formatSpecifiers(in: "%2$@ of %1$lld") == ["%@", "%lld"])
		#expect(Self.formatSpecifiers(in: "Memory: %lld MB") == ["%lld"])
		#expect(Self.formatSpecifiers(in: "%.1f%%") == ["%.1f"])
	}

	// MARK: - Display strings built in code

	/// Display strings come back in the app's current UI language, so they are matched against
	/// the catalog's keys under English and against that language's translations otherwise.
	private static func knownDisplayStrings(in catalog: Catalog) -> Set<String> {
		let language = Bundle.main.preferredLocalizations.first ?? "en"
		if language.hasPrefix("en") || !shippedLanguages.contains(language) {
			return Set(catalog.translations.keys)
		}
		return Set(catalog.translations.values.compactMap { $0[language] })
	}

	private static var enumDisplayStrings: [String] {
		var strings: [String] = []
		strings += ActivationMode.allCases.flatMap { [$0.displayName, $0.summary] }
		strings += MicStreamPolicy.allCases.flatMap { [$0.displayName, $0.summary] }
		strings += ModelUnloadTimeout.allCases.map(\.displayName)
		strings += PasteMethod.allCases.flatMap { [$0.displayName, $0.summary] }
		strings += ClipboardHandling.allCases.map(\.displayName)
		strings += AutoSubmitKey.allCases.map(\.displayName)
		strings += HistoryRetentionPeriod.allCases.map(\.displayName)
		strings += VADSensitivity.allCases.map(\.displayName)
		strings += ChineseScriptPreference.allCases.map(\.displayName)
		strings += ComputeUnitPreference.allCases.flatMap { [$0.displayName, $0.summary] }
		strings += HotkeyBackend.allCases.flatMap { [$0.title, $0.summary] }
		strings += MaterialStyle.allCases.map(\.displayName)
		strings += SupportedFormat.allCases.map(\.title)
		strings += ParakeetModel.allCases.flatMap { [$0.displayName, $0.languageSummary] }
		strings += [QueueItemStatus.pending, .processing, .completed, .failed, .cancelled].map(\.displayName)
		strings += [TranscriptionStatus.pending, .inProgress, .completed, .failed].map(\.displayName)
		return strings
	}

	@Test func everyEnumDisplayStringHasACatalogEntry() throws {
		let known = Self.knownDisplayStrings(in: try Self.loadCatalog())
		let strings = Self.enumDisplayStrings
		#expect(strings.count > 60)
		for string in strings {
			#expect(known.contains(string), "\"\(string)\" is missing from Localizable.xcstrings")
		}
	}

	@Test(arguments: ["es", "de", "fr"])
	func compiledBundleTranslatesEnumDisplayNames(language: String) throws {
		let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
		let bundle = try #require(Bundle(path: path))
		let catalog = try Self.loadCatalog()
		for key in ["Push to Talk", "Keep forever", "Neural Engine", "Paste (Cmd-V)", "Ultra Thin"] {
			let expected = try #require(catalog.translations[key]?[language])
			#expect(bundle.localizedString(forKey: key, value: nil, table: nil) == expected)
		}
	}

	@Test func whisperLanguageNamesFollowTheUILanguage() {
		#expect(Constants.localizedLanguageName(for: "german", locale: Locale(identifier: "de")) == "Deutsch")
		#expect(Constants.localizedLanguageName(for: "german", locale: Locale(identifier: "es")) == "Alemán")
		#expect(Constants.localizedLanguageName(for: "german", locale: Locale(identifier: "fr")) == "Allemand")
		#expect(Constants.localizedLanguageName(for: "german", locale: Locale(identifier: "en")) == "German")
		#expect(Constants.localizedLanguageName(for: "not-a-language") == "Not-A-Language")
	}

	@Test func localizedLanguageListKeepsEveryLanguage() {
		let sorted = Constants.localizedSortedLanguageNames(locale: Locale(identifier: "de"))
		#expect(Set(sorted) == Set(Constants.languages.keys))
	}
}
