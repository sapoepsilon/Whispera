import AppKit
import Foundation
import LinkHelperCore

// Whispera's login-item helper: the Mac side of whispera-link, kept running by launchd while
// Whispera itself is quit. `serve` is accepted so the e2e scripts can launch it like the v1 daemon.
let arguments = CommandLine.arguments.dropFirst()
guard arguments.isEmpty || arguments == ["serve"] else {
	FileHandle.standardError.write(Data("usage: WhisperaLinkHelper [serve]\n".utf8))
	exit(2)
}

/// Whispera.app/Contents/Library/LoginItems/WhisperaLinkHelper.app → Whispera.app.
let containingApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
	.deletingLastPathComponent().deletingLastPathComponent()

func launchWhisperaForApprovalCard() {
	guard containingApp.pathExtension == "app" else { return }
	let configuration = NSWorkspace.OpenConfiguration()
	configuration.activates = false
	configuration.addsToRecentItems = false
	configuration.arguments = ["--approval-card"]
	NSWorkspace.shared.openApplication(at: containingApp, configuration: configuration) { _, error in
		if let error {
			FileHandle.standardError.write(
				Data("whispera-link: cannot open Whispera for the approval card: \(error.localizedDescription)\n".utf8))
		}
	}
}

#if DEBUG
	// Debug builds keep the `WHISPERA_LINK_*` overrides so the e2e scripts can drive this binary.
	let environment = ProcessInfo.processInfo.environment
#else
	let environment = HelperEnvironment.withoutOverrides(ProcessInfo.processInfo.environment)
#endif

/// Phones transcribe with whatever engine is selected in Whispera, read from Whispera's own settings.
let appDomain = AppSpeechSelection.appDomain(helperBundleIdentifier: Bundle.main.bundleIdentifier)
exit(
	HelperRuntime.serve(
		engine: WhisperKitSpeechEngine(appDomain: appDomain, environment: environment), environment: environment,
		selection: AppSpeechSelection(domain: appDomain), speechKeys: KeychainSpeechKeyStore(),
		launchApp: launchWhisperaForApprovalCard))
