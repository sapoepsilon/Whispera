import Foundation
import Testing

struct SparkleIntegrationTests {

	private var projectRoot: String {
		// WhisperaUnitTests is at the project root level
		let testFile = #filePath
		return URL(fileURLWithPath: testFile)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.path
	}

	// MARK: - Project Configuration

	@Test func projectDoesNotEmbedXPCServicesAtAppLevel() throws {
		let pbxproj = try String(
			contentsOfFile: projectRoot + "/Whispera.xcodeproj/project.pbxproj",
			encoding: .utf8
		)
		// Sparkle 2.x requires XPC services to stay inside Sparkle.framework.
		// A build phase that copies them to Contents/XPCServices/ breaks the updater.
		#expect(
			!pbxproj.contains("Embed Sparkle XPC Services"),
			"project.pbxproj must not contain an 'Embed Sparkle XPC Services' build phase — Sparkle 2.x requires XPC services inside the framework"
		)
	}

	@Test func ciScriptDoesNotUseDeepSigning() throws {
		let script = try String(
			contentsOfFile: projectRoot + "/scripts/release-distribute-ci.sh",
			encoding: .utf8
		)
		let lines = script.components(separatedBy: "\n")
		for (index, line) in lines.enumerated() {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("#") || trimmed.hasPrefix("echo") { continue }
			if trimmed.contains("codesign") && trimmed.contains("--deep") {
				// codesign --deep is OK for verification (codesign -vvv --deep --strict)
				// but NOT for signing (codesign --force --deep)
				let isVerifyOnly =
					trimmed.contains("-vvv") || trimmed.contains("--verify")
					|| trimmed.contains("--strict")
				#expect(
					isVerifyOnly,
					"Line \(index + 1): codesign --deep must only be used for verification, not signing — it breaks Sparkle XPC services"
				)
			}
		}
	}

	@Test func infoPlistHasRequiredSparkleKeys() throws {
		let plistPath = projectRoot + "/Info.plist"
		let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
		let plist =
			try PropertyListSerialization.propertyList(from: data, format: nil)
			as? [String: Any]

		let feedURL = plist?["SUFeedURL"] as? String
		#expect(feedURL != nil, "Info.plist must have SUFeedURL")
		#expect(feedURL?.hasPrefix("https://") == true, "SUFeedURL must use HTTPS")

		let publicKey = plist?["SUPublicEDKey"] as? String
		#expect(publicKey != nil, "Info.plist must have SUPublicEDKey")
		#expect(publicKey?.isEmpty == false, "SUPublicEDKey must not be empty")
	}

	// MARK: - Built App Bundle Structure
	// These tests run inside the host app, so Bundle.main is the Whispera.app bundle.

	@Test func builtAppHasSparkleFramework() throws {
		let bundlePath = try #require(Bundle.main.bundlePath)
		let frameworkPath = bundlePath + "/Contents/Frameworks/Sparkle.framework"
		#expect(
			FileManager.default.fileExists(atPath: frameworkPath),
			"Built app must contain Sparkle.framework"
		)
	}

	@Test func builtAppHasNoAppLevelXPCServices() throws {
		let bundlePath = try #require(Bundle.main.bundlePath)
		let appXPCPath = bundlePath + "/Contents/XPCServices"
		let hasAppLevelXPC = FileManager.default.fileExists(atPath: appXPCPath)
		#expect(
			!hasAppLevelXPC,
			"Built app must NOT have Contents/XPCServices/ — Sparkle 2.x XPC services must stay inside the framework"
		)
	}

	@Test func sparkleFrameworkContainsXPCServices() throws {
		let bundlePath = try #require(Bundle.main.bundlePath)
		let xpcPath =
			bundlePath
			+ "/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices"

		#expect(
			FileManager.default.fileExists(atPath: xpcPath),
			"Sparkle.framework must contain its own XPCServices directory"
		)

		let contents = try FileManager.default.contentsOfDirectory(atPath: xpcPath)
		let xpcBundles = contents.filter { $0.hasSuffix(".xpc") }
		#expect(
			xpcBundles.count >= 2,
			"Sparkle.framework should contain at least Downloader.xpc and Installer.xpc, found: \(xpcBundles)"
		)
	}
}
