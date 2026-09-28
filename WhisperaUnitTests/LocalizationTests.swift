import Foundation
import Testing

@testable import Whispera

struct LocalizationTests {

	private static let shippedLanguages = ["es", "de", "fr"]

	private func bundle(for language: String) throws -> Bundle {
		let path = try #require(
			Bundle.main.path(forResource: language, ofType: "lproj"),
			"The app bundle has no \(language).lproj; the String Catalog did not compile for it")
		return try #require(Bundle(path: path))
	}

	@Test func appDeclaresShippedLanguages() {
		let localizations = Set(Bundle.main.localizations)
		for language in Self.shippedLanguages {
			#expect(localizations.contains(language))
		}
	}

	@Test(arguments: [
		("es", "Settings", "Ajustes"),
		("de", "Settings", "Einstellungen"),
		("fr", "Settings", "Réglages"),
		("es", "Quit Whispera", "Salir de Whispera"),
		("de", "Recording Overlay", "Aufnahmeanzeige"),
		("fr", "Storage & Downloads", "Stockage et téléchargements"),
	])
	func translatesKnownKeys(language: String, key: String, expected: String) throws {
		let localized = try bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
		#expect(localized == expected)
	}

	@Test func everyLanguageShipsTheSameKeys() throws {
		var keySets: [String: Set<String>] = [:]
		for language in Self.shippedLanguages {
			let url = try #require(
				try bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
			let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
			keySets[language] = Set(table.keys)
		}
		let reference = try #require(keySets["es"])
		#expect(reference.count > 150)
		for (language, keys) in keySets {
			#expect(keys == reference, "\(language) is missing \(reference.subtracting(keys).sorted())")
		}
	}

	@Test(arguments: ["es", "de", "fr"])
	func permissionPromptsAreLocalized(language: String) throws {
		let localized = try bundle(for: language).localizedString(
			forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
		#expect(localized.contains("Whispera"))
		#expect(localized != "Whispera needs access to your microphone to transcribe audio.")
	}
}

struct AppLanguageTests {

	private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
		let suite = "AppLanguageTests.\(name).\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	@Test func defaultsToSystem() {
		#expect(AppLanguage.stored(in: isolatedDefaults()) == .system)
	}

	@Test(arguments: [AppLanguage.english, .spanish, .german, .french])
	func storingALanguageOverridesAppleLanguages(language: AppLanguage) {
		let defaults = isolatedDefaults()
		AppLanguage.store(language, in: defaults)
		#expect(AppLanguage.stored(in: defaults) == language)
		#expect(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey) == [language.rawValue])
	}

	@Test func storingSystemRemovesTheOverride() {
		let defaults = isolatedDefaults()
		AppLanguage.store(.german, in: defaults)
		AppLanguage.store(.system, in: defaults)
		#expect(AppLanguage.stored(in: defaults) == .system)
		#expect(defaults.object(forKey: AppLanguage.appleLanguagesKey) as? [String] != ["de"])
	}

	@Test func everyNonSystemLanguageHasAnLproj() {
		for language in AppLanguage.allCases where language != .system && language != .english {
			#expect(Bundle.main.localizations.contains(language.rawValue))
		}
	}
}

struct AppRelaunchTests {
	private func makeOpener() throws -> (opener: URL, marker: URL, directory: URL) {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("AppRelaunchTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let marker = directory.appendingPathComponent("opened")
		let opener = directory.appendingPathComponent("fake-open")
		try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(marker.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
		return (opener, marker, directory)
	}

	private func runRelaunchScript(waitingFor pid: Int32, opener: URL, timeoutTicks: Int) throws -> Process {
		let script = Process()
		script.executableURL = URL(fileURLWithPath: "/bin/sh")
		script.arguments = AppLanguage.relaunchArguments(
			bundlePath: "/Applications/Whispera.app", pid: pid, opener: opener.path, timeoutTicks: timeoutTicks)
		try script.run()
		return script
	}

	@Test func opensTheAppOnlyAfterTheOldProcessHasExited() throws {
		let (opener, marker, directory) = try makeOpener()
		defer { try? FileManager.default.removeItem(at: directory) }
		let quitting = Process()
		quitting.executableURL = URL(fileURLWithPath: "/bin/sleep")
		quitting.arguments = ["1"]
		try quitting.run()

		let script = try runRelaunchScript(waitingFor: quitting.processIdentifier, opener: opener, timeoutTicks: 100)
		Thread.sleep(forTimeInterval: 0.5)
		#expect(!FileManager.default.fileExists(atPath: marker.path), "Opened while the old copy was still running")
		quitting.waitUntilExit()
		script.waitUntilExit()
		#expect(script.terminationStatus == 0)
		#expect(try String(contentsOf: marker, encoding: .utf8) == "/Applications/Whispera.app")
	}

	@Test func doesNotOpenASecondCopyWhenQuittingWasCancelled() throws {
		let (opener, marker, directory) = try makeOpener()
		defer { try? FileManager.default.removeItem(at: directory) }

		let script = try runRelaunchScript(
			waitingFor: ProcessInfo.processInfo.processIdentifier, opener: opener, timeoutTicks: 3)
		script.waitUntilExit()
		#expect(script.terminationStatus == 1)
		#expect(!FileManager.default.fileExists(atPath: marker.path))
	}
}
