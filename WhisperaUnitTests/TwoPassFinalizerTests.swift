// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import Testing

@testable import Whispera

/// The pure halves of the two-pass finalizer: the PCM16 → Float32 downsample
/// the second pass feeds WhisperKit, the mode table, and the fallback policy
/// that decides whether the polished text or the streaming draft is pasted.
/// The wiring around them lives in `StreamingTranscriber.finalizeDictation`.

private func pcm16Data(_ samples: [Int16]) -> Data {
	var data = Data(capacity: samples.count * 2)
	for sample in samples {
		withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
	}
	return data
}

struct PCM16ResamplerTests {
	@Test func emptyDataProducesNoSamples() {
		#expect(
			PCM16Resampler.float32Samples(fromPCM16LittleEndian: Data(), sourceHz: 24000, targetHz: 16000)
				.isEmpty)
	}

	@Test func aTrailingOddByteIsDropped() {
		var data = pcm16Data([1000])
		data.append(0x7F)
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: data, sourceHz: 16000, targetHz: 16000)
		#expect(samples.count == 1)
	}

	@Test func sameRatePassthroughConvertsKnownValues() {
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: pcm16Data([0, 16384, -16384, Int16.max, Int16.min]),
			sourceHz: 16000, targetHz: 16000)
		#expect(samples.count == 5)
		#expect(samples[0] == 0)
		#expect(abs(samples[1] - 0.5) < 0.001)
		#expect(abs(samples[2] + 0.5) < 0.001)
		// Divided by 32768, so the extremes stay inside [-1, 1) exactly.
		#expect(abs(samples[3] - 32767.0 / 32768.0) < 0.0001)
		#expect(samples[4] == -1.0)
	}

	@Test func downsampleKeepsTwoThirdsOfTheSamples() {
		let data = pcm16Data([Int16](repeating: 100, count: 2400))
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: data, sourceHz: 24000, targetHz: 16000)
		#expect(samples.count == 1600)
	}

	@Test func downsamplePreservesADCSignal() {
		let data = pcm16Data([Int16](repeating: 16384, count: 300))
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: data, sourceHz: 24000, targetHz: 16000)
		#expect(samples.allSatisfy { abs($0 - 0.5) < 0.001 })
	}

	@Test func downsampleInterpolatesLinearlyBetweenNeighbours() {
		// A ramp 0, 3000, 6000, ... sampled at 1.5x spacing must land halfway
		// between neighbours on the odd output indices: positions 0, 1.5, 3, 4.5.
		let ramp = (0..<8).map { Int16($0 * 3000) }
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: pcm16Data(ramp), sourceHz: 24000, targetHz: 16000)
		let expected: [Float] = [0, 4500, 9000, 13500, 18000].map { $0 / 32768.0 }
		#expect(samples.count >= expected.count)
		for (index, value) in expected.enumerated() {
			#expect(abs(samples[index] - value) < 0.001)
		}
	}

	@Test func aSingleSampleSurvivesWithoutInterpolationPartners() {
		let samples = PCM16Resampler.float32Samples(
			fromPCM16LittleEndian: pcm16Data([16384, 16384]), sourceHz: 24000, targetHz: 16000)
		#expect(samples.count == 1)
		#expect(abs(samples[0] - 0.5) < 0.001)
	}

	@Test func nonsenseRatesProduceNothingRatherThanTrapping() {
		let data = pcm16Data([1, 2, 3])
		#expect(
			PCM16Resampler.float32Samples(fromPCM16LittleEndian: data, sourceHz: 0, targetHz: 16000)
				.isEmpty)
		#expect(
			PCM16Resampler.float32Samples(fromPCM16LittleEndian: data, sourceHz: 24000, targetHz: 0)
				.isEmpty)
	}
}

struct TwoPassFinalizerModeTests {
	@Test func unknownAndAbsentRawValuesReadAsOff() {
		#expect(TwoPassFinalizerMode.from(nil) == .off)
		#expect(TwoPassFinalizerMode.from("") == .off)
		#expect(TwoPassFinalizerMode.from("cloud-gpu") == .off)
	}

	@Test func storedModesRoundTrip() {
		#expect(TwoPassFinalizerMode.from("local") == .local)
		#expect(TwoPassFinalizerMode.from("server") == .server)
		#expect(TwoPassFinalizerMode.from("off") == .off)
	}

	@Test func onlyOffIsOff() {
		#expect(!TwoPassFinalizerMode.off.isOn)
		#expect(TwoPassFinalizerMode.local.isOn)
		#expect(TwoPassFinalizerMode.server.isOn)
	}

	/// The deadlines are the contract the stop path's boundedness rests on.
	@Test func deadlinesMatchTheDesign() {
		#expect(TwoPassFinalizerMode.local.deadline == 10)
		#expect(TwoPassFinalizerMode.server.deadline == 15)
	}
}

struct TwoPassPolicyTests {
	@Test func aFinalizedTranscriptWinsTrimmed() {
		#expect(TwoPassPolicy.finalizedText(from: .finalized("  polished text ")) == "polished text")
		#expect(TwoPassPolicy.fallbackReason(for: .finalized("polished text")) == nil)
	}

	@Test func anEmptyFinalizedTranscriptFallsBackToTheDraft() {
		#expect(TwoPassPolicy.finalizedText(from: .finalized("   \n ")) == nil)
		#expect(TwoPassPolicy.fallbackReason(for: .finalized("  ")) != nil)
	}

	@Test func everyNonFinalizedOutcomeFallsBackWithAReason() {
		let outcomes: [TwoPassOutcome] = [
			.failed("the upload failed"), .deadlineExpired, .superseded, .noAudio,
		]
		for outcome in outcomes {
			#expect(TwoPassPolicy.finalizedText(from: outcome) == nil)
			#expect(TwoPassPolicy.fallbackReason(for: outcome) != nil)
		}
	}

	@Test func aFailureCarriesItsOwnReasonIntoTheLog() {
		#expect(TwoPassPolicy.fallbackReason(for: .failed("engine said no")) == "engine said no")
	}
}

struct TwoPassDeadlineTests {
	@Test func aFastPassWinsTheRace() async {
		let outcome = await TwoPassDeadline.race(seconds: 5) { .finalized("quick") }
		#expect(outcome == .finalized("quick"))
	}

	@Test func aSlowPassLosesToTheDeadline() async {
		let start = Date()
		let outcome = await TwoPassDeadline.race(seconds: 0.05) {
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			return .finalized("too late")
		}
		#expect(outcome == .deadlineExpired)
		// The race must resolve at the deadline, not when the loser finishes.
		#expect(Date().timeIntervalSince(start) < 2)
	}

	@Test func cancellingTheRaceResolvesSuperseded() async {
		let race = Task {
			await TwoPassDeadline.race(seconds: 30) {
				try? await Task.sleep(nanoseconds: 30_000_000_000)
				return .finalized("never")
			}
		}
		try? await Task.sleep(nanoseconds: 50_000_000)
		race.cancel()
		let outcome = await race.value
		#expect(outcome == .superseded)
	}

	@Test func aZeroDeadlineRunsThePassUnraced() async {
		let outcome = await TwoPassDeadline.race(seconds: 0) { .finalized("direct") }
		#expect(outcome == .finalized("direct"))
	}
}
