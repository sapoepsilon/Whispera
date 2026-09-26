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

	@Test func onlyTheModelScriptReadsTheTokenItself() {
		let byName = Dictionary(uniqueKeysWithValues: RaycastScripts.commands().map { ($0.fileName, $0.body) })
		let body = byName["whispera-set-model.sh"] ?? ""
		#expect(body.contains(RaycastScripts.tokenLine))
		#expect(body.contains("token=$token"))
		for name in byName.keys where name != "whispera-set-model.sh" {
			#expect(!(byName[name] ?? "").contains("token="), "\(name)")
		}
		let tokenPath = RemoteControlToken.fileURL().path
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		#expect(tokenPath.hasPrefix(home))
		#expect(RaycastScripts.tokenLine.contains(tokenPath.replacingOccurrences(of: home, with: "$HOME")))
	}

	@Test func linkOnlyScriptsExplainThatLinksAreOff() throws {
		let domain = "RaycastScriptsTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: domain))
		defer { defaults.removePersistentDomain(forName: domain) }
		let check = RaycastScripts.linksEnabledCheck(bundleIdentifier: domain)
		let script = "\(check)\necho ran"

		#expect(try runBash(script) == RaycastScripts.linksOffHint + "\n")
		defaults.set(true, forKey: RemoteControlSettings.urlSchemeEnabledKey)
		defaults.synchronize()
		#expect(try runBash(script) == "ran\n")

		for command in RaycastScripts.commands() where command.body.contains("open -g \"whispera://") {
			#expect(command.body.hasPrefix(RaycastScripts.linksEnabledCheck(bundleIdentifier: RaycastScripts.defaultBundleIdentifier)), "\(command.fileName)")
		}
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

	@Test func dictationScriptsGoThroughTheCLISoItCanReportRefusals() throws {
		let expected: [String: RemoteCommand] = [
			"whispera-toggle.sh": .toggle,
			"whispera-start.sh": .start,
			"whispera-stop.sh": .stop,
			"whispera-cancel.sh": .cancel,
			"whispera-copy-last.sh": .copyLastTranscript,
			"whispera-history.sh": .openHistory,
		]
		for command in RaycastScripts.commands() {
			guard let remote = expected[command.fileName] else { continue }
			let invocation = try #require(
				command.body.split(separator: "\n").first { $0.hasPrefix("\"$WHISPERA\"") })
			let flag = String(invocation.split(separator: " ")[1])
			#expect(try CLIOptions.parse([flag]).action == .remote(remote), "\(command.fileName)")
			#expect(invocation.hasSuffix("2>&1"), "Raycast shows stdout, so the CLI's error must reach it")
		}
		#expect(Set(RaycastScripts.commands().map(\.fileName)).isSuperset(of: expected.keys))
	}

	@Test func cliScriptsUseTheGivenBinaryButAllowOverride() {
		let scripts = RaycastScripts.commands(cliPath: "/tmp/Test.app/Contents/MacOS/Whispera")
		let cliScripts = scripts.filter { $0.body.contains("$WHISPERA") }
		#expect(cliScripts.count == 9)
		for script in cliScripts {
			#expect(script.body.contains("${WHISPERA_CLI:-/tmp/Test.app/Contents/MacOS/Whispera}"))
		}
	}

	@Test func addWordScriptPassesTheArgumentThroughTheCLI() throws {
		let script = try #require(RaycastScripts.commands().first { $0.fileName == "whispera-add-word.sh" })
		#expect(script.argumentPlaceholder != nil)
		#expect(script.body.contains("\"$WHISPERA\" --add-word \"$1\" 2>&1"))
		let options = try CLIOptions.parse(["--add-word", "Kubernetes, Grafana"])
		#expect(options.action == .remote(.addWord("Kubernetes, Grafana")))
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
