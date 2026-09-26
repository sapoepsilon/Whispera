import Foundation
import Testing

@testable import Whispera

struct RaycastScriptsTests {
	static let committedDirectory = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("integrations/raycast")

	@Test func everyScriptHasRequiredRaycastMetadata() {
		for command in RaycastScripts.commands() {
			let script = command.render()
			#expect(script.hasPrefix("#!/bin/bash\n"), "\(command.fileName)")
			#expect(script.contains("# @raycast.schemaVersion 1"), "\(command.fileName)")
			#expect(script.contains("# @raycast.title \(command.title)"), "\(command.fileName)")
			#expect(script.contains("# @raycast.mode \(command.mode.rawValue)"), "\(command.fileName)")
			#expect(script.contains("# @raycast.packageName Whispera"), "\(command.fileName)")
			#expect(script.contains("@raycast.argument1") == (command.argumentPlaceholder != nil))
		}
	}

	@Test func micScriptsReadTheTokenAtRunTimeAndSafeOnesDoNot() {
		let byName = Dictionary(uniqueKeysWithValues: RaycastScripts.commands().map { ($0.fileName, $0.body) })
		for name in ["whispera-toggle.sh", "whispera-start.sh", "whispera-set-model.sh"] {
			let body = byName[name] ?? ""
			#expect(body.contains(RaycastScripts.tokenLine), "\(name)")
			#expect(body.contains("token=$token"), "\(name)")
		}
		for name in ["whispera-stop.sh", "whispera-cancel.sh", "whispera-set-language.sh"] {
			#expect(!(byName[name] ?? "").contains("token"), "\(name)")
		}
		let tokenPath = RemoteControlToken.fileURL().path
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		#expect(tokenPath.hasPrefix(home))
		#expect(RaycastScripts.tokenLine.contains(tokenPath.replacingOccurrences(of: home, with: "$HOME")))
	}

	@Test func tokenLineReadsTheTokenFileInBash() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent("raycast-home-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: home) }
		let directory = home.appendingPathComponent("Library/Application Support/Whispera")
		let token = try RemoteControlToken.regenerate(in: directory)
		#expect(try runBash("\(RaycastScripts.tokenLine)\nprintf %s \"$token\"", home: home.path) == token)
	}

	@Test func cliPathWithShellMetacharactersIsEscaped() throws {
		let hostile = "/tmp/We\"ird $(echo pwned) `id` \\x/Whispera"
		let scripts = RaycastScripts.commands(cliPath: hostile)
		let body = try #require(scripts.first { $0.fileName == "whispera-list-models.sh" }).body
		let assignment = try #require(body.split(separator: "\n").first { $0.hasPrefix("WHISPERA=") })
		#expect(try runBash("unset WHISPERA_CLI\n\(assignment)\nprintf %s \"$WHISPERA\"") == hostile)
	}

	private func runBash(_ script: String, home: String? = nil) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = ["-c", script]
		if let home { process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"] }
		let pipe = Pipe()
		process.standardOutput = pipe
		try process.run()
		process.waitUntilExit()
		return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
	}

	@Test func dictationScriptsOpenURLsTheAppUnderstands() throws {
		let expected: [String: RemoteCommand] = [
			"whispera-toggle.sh": .toggle,
			"whispera-start.sh": .start,
			"whispera-stop.sh": .stop,
			"whispera-cancel.sh": .cancel,
		]
		for command in RaycastScripts.commands() {
			guard let remote = expected[command.fileName] else { continue }
			let urlString = try #require(
				command.body.split(separator: "\"").first { $0.hasPrefix("whispera://") }.map(String.init))
			let url = try #require(URL(string: urlString))
			#expect(RemoteCommand(url: url) == remote)
		}
		#expect(Set(RaycastScripts.commands().map(\.fileName)).isSuperset(of: expected.keys))
	}

	@Test func cliScriptsUseTheGivenBinaryButAllowOverride() {
		let scripts = RaycastScripts.commands(cliPath: "/tmp/Test.app/Contents/MacOS/Whispera")
		let cliScripts = scripts.filter { $0.body.contains("$WHISPERA") }
		#expect(cliScripts.count == 2)
		for script in cliScripts {
			#expect(script.body.contains("${WHISPERA_CLI:-/tmp/Test.app/Contents/MacOS/Whispera}"))
		}
	}

	@Test func exportWritesExecutableScripts() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raycast-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let urls = try RaycastScripts.export(to: directory)
		#expect(urls.count == RaycastScripts.commands().count)
		for url in urls {
			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
			#expect(permissions & 0o111 == 0o111, "\(url.lastPathComponent) must be executable")
		}
	}

	@Test(.enabled(if: FileManager.default.fileExists(atPath: committedDirectory.path)))
	func committedScriptsMatchTheGenerator() throws {
		for command in RaycastScripts.commands() {
			let url = Self.committedDirectory.appendingPathComponent(command.fileName)
			let committed = try String(contentsOf: url, encoding: .utf8)
			#expect(committed == command.render(), "Regenerate integrations/raycast/\(command.fileName)")
		}
	}
}
