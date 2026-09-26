import Foundation
import Testing

@testable import Whispera

struct UpdateSignatureVerifierTests {
	@Test func requirementPinsTheDeveloperIDTeamAndBundle() {
		#expect(UpdateSignatureVerifier.requirement.contains("certificate leaf[subject.OU] = \"NK28QT38A3\""))
		#expect(UpdateSignatureVerifier.requirement.contains("identifier \"com.macwhisper.app\""))
		#expect(UpdateSignatureVerifier.requirement.hasPrefix("anchor apple generic"))
	}

	@Test func rejectsAnAppleSignedAppFromAnotherTeam() throws {
		let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
		try #require(FileManager.default.fileExists(atPath: calculator.path))
		#expect(throws: UpdateSignatureError.self) {
			try UpdateSignatureVerifier.verify(appAt: calculator)
		}
	}

	@Test func rejectsAnUnsignedBundle() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let app = try UpdateTestFixtures.makeFakeApp(in: directory)
		#expect(throws: UpdateSignatureError.self) {
			try UpdateSignatureVerifier.verify(appAt: app)
		}
	}

	@Test(
		.enabled(
			if: FileManager.default.fileExists(atPath: "/Applications/Whispera.app"),
			"Needs a Developer ID build of Whispera installed"))
	func acceptsTheInstalledDeveloperIDBuild() throws {
		try UpdateSignatureVerifier.verify(appAt: URL(fileURLWithPath: "/Applications/Whispera.app"))
	}
}

@MainActor
struct UpdateInstallVerificationTests {
	@Test func refusesToInstallADiskImageWhoseAppIsNotOurs() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstall-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let applications = root.appendingPathComponent("Applications")
		try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
		let installed = applications.appendingPathComponent("Whispera.app")
		try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
		try Data("current".utf8).write(to: installed.appendingPathComponent("marker"))

		let source = root.appendingPathComponent("source")
		_ = try UpdateTestFixtures.makeFakeApp(in: source)
		let dmg = root.appendingPathComponent("Whispera-99.0.0.dmg")
		try UpdateTestFixtures.makeDiskImage(from: source, at: dmg)

		let checked = CheckedApps()
		let manager = UpdateManager(
			downloadsDirectory: root.appendingPathComponent("Downloads"), applicationsDirectory: applications,
			verifyApp: { app in
				checked.record(app)
				try UpdateSignatureVerifier.verify(appAt: app)
			})
		let succeeded = await manager.installUpdate(from: dmg.path)

		#expect(!succeeded)
		#expect(checked.count == 1, "The image must be mounted and its app checked before anything moves")
		#expect(
			try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8) == "current",
			"The installed app must be left alone")
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
		#expect(leftovers == ["Whispera.app"], "No staged copy may be left behind")
	}

	@Test func installOnlyEverUsesTheFileThisProcessDownloaded() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdatePlanted-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let downloads = root.appendingPathComponent("Downloads")
		try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
		let manager = UpdateManager(downloadsDirectory: downloads, applicationsDirectory: root)
		manager.latestVersion = "99.0.0"
		FileManager.default.createFile(
			atPath: downloads.appendingPathComponent("Whispera-99.0.0.dmg").path, contents: Data("planted".utf8))

		#expect(!manager.isUpdateDownloaded)
		await #expect(throws: UpdateError.downloadFailed) {
			try await manager.installDownloadedUpdate()
		}
	}
}

final class CheckedApps: @unchecked Sendable {
	private let lock = NSLock()
	private var apps: [URL] = []

	func record(_ app: URL) {
		lock.withLock { apps.append(app) }
	}

	var count: Int { lock.withLock { apps.count } }
}

enum UpdateTestFixtures {
	/// A bundle shaped like Whispera.app with an unsigned executable.
	static func makeFakeApp(in directory: URL) throws -> URL {
		let app = directory.appendingPathComponent("Whispera.app")
		let macOS = app.appendingPathComponent("Contents/MacOS")
		try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
		let plist: [String: Any] = [
			"CFBundleIdentifier": "com.macwhisper.app", "CFBundleExecutable": "Whispera",
			"CFBundlePackageType": "APPL",
		]
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
		let executable = macOS.appendingPathComponent("Whispera")
		try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
		return app
	}

	static func makeDiskImage(from folder: URL, at destination: URL) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
		process.arguments = [
			"create", "-quiet", "-srcfolder", folder.path, "-volname", "WhisperaTest-\(UUID().uuidString.prefix(8))",
			"-format", "UDRO", "-ov", destination.path,
		]
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
		}
	}
}
