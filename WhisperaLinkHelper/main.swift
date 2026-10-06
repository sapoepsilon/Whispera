import Foundation
import LinkHelperCore

// Whispera's login-item helper: the Mac side of whispera-link, kept running by launchd while
// Whispera itself is quit. `serve` is accepted so the e2e scripts can launch it like the v1 daemon.
let arguments = CommandLine.arguments.dropFirst()
guard arguments.isEmpty || arguments == ["serve"] else {
	FileHandle.standardError.write(Data("usage: WhisperaLinkHelper [serve]\n".utf8))
	exit(2)
}
exit(HelperRuntime.serve(engine: WhisperKitSpeechEngine()))
