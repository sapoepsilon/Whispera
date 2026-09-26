import Foundation

@main
enum WhisperaMain {
	static func main() {
		let arguments = Array(CommandLine.arguments.dropFirst())
		guard WhisperaCLI.isCLIInvocation(arguments) else {
			WhisperaApp.main()
			return
		}

		// Headless runs never start NSApplication, so no menu bar item, windows or
		// single-instance handoff; the main queue just services async work until exit.
		Task.detached {
			let status = await WhisperaCLI.run(arguments: arguments)
			exit(status)
		}
		dispatchMain()
	}
}
