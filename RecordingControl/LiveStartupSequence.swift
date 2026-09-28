import Foundation

/// The steps a live session runs once its model is ready, in order. The microphone opens
/// first: preparing the custom-word prompt can load a prewarmed model's weights, which takes
/// seconds (tens on a busy Mac), and the words said meanwhile must already be captured.
@MainActor
enum LiveStartupSequence {
	static func run(
		openMicrophone: () async throws -> Void,
		preparePrompt: () async -> Void,
		isCurrent: () -> Bool,
		startDecoding: () -> Void
	) async throws {
		try await openMicrophone()
		guard isCurrent() else { throw CancellationError() }
		await preparePrompt()
		guard isCurrent() else { throw CancellationError() }
		startDecoding()
	}
}
