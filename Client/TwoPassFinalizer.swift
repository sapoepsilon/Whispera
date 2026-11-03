// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation

/// Which engine re-reads the whole utterance once a live dictation stops.
///
/// The streaming engine commits words with no right context, which is what
/// makes it fast and what caps its accuracy. A second pass over the session's
/// retained audio trades the instant paste for a short "polishing" wait — only
/// when the user turned it on, which is why `off` is the default.
enum TwoPassFinalizerMode: String, CaseIterable, Sendable {
	case off
	case local
	case server

	/// Tolerates any stored garbage: a raw value from a build that shipped a
	/// mode this one no longer does must degrade to off, not trap.
	static func from(_ raw: String?) -> TwoPassFinalizerMode {
		raw.flatMap(TwoPassFinalizerMode.init(rawValue:)) ?? .off
	}

	var isOn: Bool { self != .off }

	/// Hard ceiling on the polishing wait. The user is staring at a HUD with
	/// nothing pasted, so a pass that overruns is abandoned in favour of the
	/// draft they would have had instantly. The server pass gets more headroom
	/// because an upload rides the network on top of the transcription itself.
	var deadline: TimeInterval {
		switch self {
		case .off: return 0
		case .local: return 10
		case .server: return 15
		}
	}

	var displayName: String {
		switch self {
		case .off: return "Off"
		case .local: return "On-device Whisper"
		case .server: return "Server Whisper"
		}
	}
}

extension WhisperaSettings {
	static let twoPassFinalizerKey = "whisperaTwoPassFinalizer"

	/// Read at dictation start and held for the session, so flipping it in
	/// Settings mid-recording changes the next dictation, not the running one.
	static var twoPassFinalizer: TwoPassFinalizerMode {
		get { .from(UserDefaults.standard.string(forKey: twoPassFinalizerKey)) }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: twoPassFinalizerKey) }
	}
}

/// Little-endian mono PCM16 to the Float32 buffer the on-device engine and the
/// WAV wrapper both want, resampled by linear interpolation.
///
/// Linear rather than AVAudioConverter because the input is raw `Data` off the
/// session's retention buffer, not an AVAudioPCMBuffer, and a pure function
/// over bytes is testable without CoreAudio. The missing low-pass means
/// content between the target and source Nyquist (8–12 kHz for 24 kHz → 16 kHz)
/// can alias, but speech energy sits almost entirely below 8 kHz and the
/// second pass exists for words, not fidelity.
enum PCM16Resampler {
	static func float32Samples(
		fromPCM16LittleEndian data: Data, sourceHz: Int, targetHz: Int
	) -> [Float] {
		guard sourceHz > 0, targetHz > 0 else { return [] }
		// A trailing odd byte cannot be half a sample; dropping it beats letting
		// it shift every later sample into byte-swapped noise.
		let sampleCount = data.count / 2
		guard sampleCount > 0 else { return [] }

		var source = [Float](repeating: 0, count: sampleCount)
		data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			for index in 0..<sampleCount {
				let low = UInt16(raw[index * 2])
				let high = UInt16(raw[index * 2 + 1])
				let value = Int16(bitPattern: (high << 8) | low)
				// Divided by 32768 rather than Int16.max so -32768 lands exactly
				// on -1.0 and no sample can leave [-1, 1).
				source[index] = Float(value) / 32768.0
			}
		}
		if sourceHz == targetHz { return source }

		let ratio = Double(sourceHz) / Double(targetHz)
		let outputCount = Int((Double(sampleCount) / ratio).rounded(.down))
		guard outputCount > 0 else { return [] }

		var output = [Float](repeating: 0, count: outputCount)
		for n in 0..<outputCount {
			let position = Double(n) * ratio
			let index = Int(position)
			let fraction = Float(position - Double(index))
			let current = source[index]
			// The last output sample can land on the final input sample exactly;
			// clamping the neighbour keeps the interpolation in bounds.
			let next = index + 1 < sampleCount ? source[index + 1] : current
			output[n] = current + (next - current) * fraction
		}
		return output
	}
}

/// How a second pass ended. One case carries text; every other case is a
/// reason the streaming draft gets pasted instead.
enum TwoPassOutcome: Equatable, Sendable {
	case finalized(String)
	case failed(String)
	case deadlineExpired
	case superseded
	case noAudio
}

/// The fallback policy, pure so the whole decision table is testable: the
/// finalizer's text wins only when it actually produced words; everything
/// else — failure, deadline, supersession, silence — falls back to the draft.
enum TwoPassPolicy {
	/// The polished text to paste, or nil when the draft must be pasted.
	static func finalizedText(from outcome: TwoPassOutcome) -> String? {
		guard case .finalized(let text) = outcome else { return nil }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// One line for the log naming why the draft is being pasted; nil when the
	/// finalizer won and there is nothing to explain.
	static func fallbackReason(for outcome: TwoPassOutcome) -> String? {
		switch outcome {
		case .finalized(let text):
			return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				? "the second pass heard no speech" : nil
		case .failed(let reason):
			return reason
		case .deadlineExpired:
			return "the second pass overran its deadline"
		case .superseded:
			return "a newer dictation superseded the pass"
		case .noAudio:
			return "the session retained no audio"
		}
	}
}

/// Races a finalize pass against a wall clock, off the main actor.
///
/// Not a task group: a group waits for every child at scope exit, so a
/// transcription that ignores its deadline would hold the "deadline" result
/// hostage until it finished anyway. And not main-actor-inherited children:
/// 845d8af showed a deadline timer that inherits a wedged main actor starves
/// together with it and never fires. Two detached tasks race to resolve one
/// continuation; the loser resumes into nothing, and the work task is left to
/// wind down in the background after a cancel it is free to ignore.
enum TwoPassDeadline {
	static func race(
		seconds: TimeInterval,
		operation: @escaping @Sendable () async -> TwoPassOutcome
	) async -> TwoPassOutcome {
		guard seconds > 0 else { return await operation() }

		let winner = FirstOutcome()
		let work = Task.detached {
			winner.resolve(await operation())
		}
		let deadline = Task.detached {
			do {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				winner.resolve(.deadlineExpired)
			} catch {
				// The only way this sleep throws is cancellation, and the only
				// cancellation route is the race's own task — a newer dictation
				// ending the wait.
				winner.resolve(.superseded)
			}
		}
		let outcome = await withTaskCancellationHandler {
			await winner.value
		} onCancel: {
			winner.resolve(.superseded)
		}
		work.cancel()
		deadline.cancel()
		return outcome
	}
}

/// Delivers the first outcome to exactly one waiter, whichever racer resolves
/// first — same shape as `StreamingTranscriber`'s `ResumeOnce`, but carrying a
/// value and tolerant of resolving before the waiter arrives.
private final class FirstOutcome: @unchecked Sendable {
	private let lock = NSLock()
	private var outcome: TwoPassOutcome?
	private var continuation: CheckedContinuation<TwoPassOutcome, Never>?

	func resolve(_ outcome: TwoPassOutcome) {
		lock.lock()
		guard self.outcome == nil else {
			lock.unlock()
			return
		}
		self.outcome = outcome
		let waiting = continuation
		continuation = nil
		lock.unlock()
		waiting?.resume(returning: outcome)
	}

	var value: TwoPassOutcome {
		get async {
			await withCheckedContinuation { (waiting: CheckedContinuation<TwoPassOutcome, Never>) in
				lock.lock()
				if let outcome {
					lock.unlock()
					waiting.resume(returning: outcome)
				} else {
					continuation = waiting
					lock.unlock()
				}
			}
		}
	}
}
