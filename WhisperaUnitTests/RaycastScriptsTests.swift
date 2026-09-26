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

	@Test func dictationScriptsOpenURLsTheAppUnderstands() throws {
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
		#expect(cliScripts.count == 3)
		for script in cliScripts {
			#expect(script.body.contains("${WHISPERA_CLI:-/tmp/Test.app/Contents/MacOS/Whispera}"))
		}
	}

	@Test func addWordScriptPassesTheArgumentThroughTheCLI() throws {
		let script = try #require(RaycastScripts.commands().first { $0.fileName == "whispera-add-word.sh" })
		#expect(script.argumentPlaceholder != nil)
		#expect(script.body.contains("\"$WHISPERA\" --add-word \"$1\""))
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
