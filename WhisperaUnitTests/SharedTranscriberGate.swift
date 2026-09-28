import Testing

/// One process-wide FIFO lock for tests that drive `WhisperKitTranscriber.shared` or the model
/// preferences it keeps in `UserDefaults.standard`. Swift Testing runs suites in parallel and
/// `.serialized` only orders tests inside a single suite, so without this a history
/// re-transcription could hold a model-use lease while an idle-unload test asserts there is none,
/// or the Parakeet test could swap the engine under another suite's transcription.
actor SharedTranscriberGate {
	static let shared = SharedTranscriberGate()

	private var isHeld = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func acquire() async {
		guard isHeld else {
			isHeld = true
			return
		}
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		if waiters.isEmpty {
			isHeld = false
		} else {
			// Ownership passes straight to the next waiter, so isHeld stays true
			waiters.removeFirst().resume()
		}
	}

	func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
		await acquire()
		do {
			let result = try await body()
			release()
			return result
		} catch {
			release()
			throw error
		}
	}
}

/// Runs each test it covers while holding `SharedTranscriberGate`. Put it on every test or suite
/// that touches the shared transcriber.
struct SharedTranscriberTrait: TestTrait, SuiteTrait, TestScoping {
	var isRecursive: Bool { true }

	func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
		// Suites get no scope of their own: holding the gate there and again for each test inside
		// would deadlock, and a suite-wide hold would also block unrelated suites for longer.
		testCase == nil ? nil : self
	}

	func provideScope(
		for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
	) async throws {
		try await SharedTranscriberGate.shared.withExclusiveAccess(function)
	}
}

extension Trait where Self == SharedTranscriberTrait {
	static var sharedTranscriber: Self { Self() }
}
