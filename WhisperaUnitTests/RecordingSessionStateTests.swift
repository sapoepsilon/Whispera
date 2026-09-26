import AVFoundation
import Foundation
import Testing

@testable import Whispera

struct DictationSessionLedgerTests {
	@Test func sessionKeepsItsOwnModeAndPostProcessFlag() {
		var ledger = DictationSessionLedger()
		let first = ledger.beginCapture(mode: .text, postProcess: true).session
		ledger.finishCapture()
		let second = ledger.beginCapture(mode: .liveTranscription, postProcess: false).session

		#expect(first.postProcess)
		#expect(first.mode == .text)
		#expect(!second.postProcess)
		#expect(ledger.transcribing == [first])
		#expect(ledger.capturing == second)
	}

	@Test func sessionIsTranscribingFromTheMomentCaptureStops() {
		var ledger = DictationSessionLedger()
		let session = ledger.beginCapture(mode: .text, postProcess: false).session
		#expect(!ledger.isTranscribing)
		let r1 = ledger.finishCapture()
		#expect(r1 == session)
		#expect(ledger.isTranscribing)
		#expect(ledger.isTranscribing(session.id))
		#expect(ledger.capturing == nil)
	}

	@Test func cancelBetweenStopAndTranscriptionReachesTheSession() {
		var ledger = DictationSessionLedger()
		let session = ledger.beginCapture(mode: .text, postProcess: false).session
		ledger.finishCapture()

		let r2 = ledger.cancel()
		#expect(r2 == [session])
		#expect(ledger.isCancelled(session.id))
		#expect(!ledger.isTranscribing)
		ledger.completeTranscription(session.id)
		#expect(!ledger.isCancelled(session.id))
	}

	@Test func cancelDuringANewCaptureSparesTheEarlierTranscription() {
		var ledger = DictationSessionLedger()
		let earlier = ledger.beginCapture(mode: .text, postProcess: false).session
		ledger.finishCapture()
		let current = ledger.beginCapture(mode: .text, postProcess: false).session

		let r3 = ledger.cancel()
		#expect(r3 == [current])
		#expect(!ledger.isCancelled(earlier.id))
		#expect(ledger.isTranscribing(earlier.id))
		#expect(ledger.capturing == nil)

		let r4 = ledger.cancel()
		#expect(r4 == [earlier])
		#expect(ledger.isCancelled(earlier.id))
	}

	@Test func completingOneTranscriptionLeavesTheOtherRunning() {
		var ledger = DictationSessionLedger()
		let a = ledger.beginCapture(mode: .text, postProcess: false).session
		ledger.finishCapture()
		let b = ledger.beginCapture(mode: .text, postProcess: true).session
		ledger.finishCapture()

		ledger.completeTranscription(a.id)
		#expect(ledger.isTranscribing)
		#expect(ledger.transcribing == [b])
		ledger.completeTranscription(b.id)
		#expect(!ledger.isTranscribing)
	}

	@Test func captureThatNeverFinishedIsReportedAsAbandoned() {
		var ledger = DictationSessionLedger()
		let dead = ledger.beginCapture(mode: .text, postProcess: false).session
		let (next, abandoned) = ledger.beginCapture(mode: .text, postProcess: false)
		#expect(abandoned == dead)
		#expect(next.id == dead.id + 1)
		#expect(!ledger.isTranscribing)
	}

	@Test func droppedCaptureIsNotTranscribed() {
		var ledger = DictationSessionLedger()
		let session = ledger.beginCapture(mode: .text, postProcess: false).session
		let r5 = ledger.dropCapture()
		#expect(r5 == session)
		let r6 = ledger.dropCapture()
		#expect(r6 == nil)
		#expect(!ledger.isTranscribing)
		let r7 = ledger.cancel()
		#expect(r7.isEmpty)
	}

	@Test func sessionIdentityIsCheckedAgainstTheLiveCapture() {
		var ledger = DictationSessionLedger()
		let session = ledger.beginCapture(mode: .text, postProcess: false).session
		#expect(ledger.isCapturing(session.id))
		ledger.finishCapture()
		#expect(!ledger.isCapturing(session.id))
	}
}

struct StreamCaptureBufferTests {
	private func monoBuffer(_ samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer {
		let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
		buffer.frameLength = AVAudioFrameCount(samples.count)
		for (index, sample) in samples.enumerated() {
			buffer.floatChannelData![0][index] = sample
		}
		return buffer
	}

	/// A stereo input with speech on its right channel only (an interface with the mic in
	/// input 2) came through "All channels" as silence: the converter kept channel 1.
	@Test func mixingAllChannelsKeepsAudioOnTheSecondChannel() throws {
		let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
		let frames = 4800
		let stereo = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
		stereo.frameLength = AVAudioFrameCount(frames)
		for index in 0..<frames {
			stereo.floatChannelData![0][index] = 0
			stereo.floatChannelData![1][index] = sin(Float(index) * 2 * .pi * 440 / 48000) * 0.5
		}
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		_ = buffer.ingest(stereo, format: format)
		let samples = buffer.finishCapture()
		#expect(!samples.isEmpty)
		#expect((samples.map(abs).max() ?? 0) > 0.1)
	}

	@Test func dropsAudioWhileNotCapturing() {
		let buffer = StreamCaptureBuffer()
		#expect(!buffer.append([1, 2, 3]))
		#expect(buffer.count == 0)
	}

	@Test func finishCaptureHandsBackAndClearsAtomically() {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		buffer.append([1, 2, 3])
		#expect(buffer.finishCapture() == [1, 2, 3])
		#expect(!buffer.isCapturing)
		#expect(buffer.count == 0)
		#expect(!buffer.append([4]))
	}

	@Test func pausingCaptureKeepsSamplesForADeviceSwitch() {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		buffer.append([1, 2])
		buffer.setCapturing(false)
		#expect(!buffer.append([9]))
		buffer.setCapturing(true)
		buffer.append([3])
		#expect(buffer.finishCapture() == [1, 2, 3])
	}

	/// The cap used to overwrite the start of a long recording without telling anyone.
	@Test func capKeepsTheBeginningAndSignalsOnce() {
		let buffer = StreamCaptureBuffer(maxSamples: 4)
		let signals = LockedCounter()
		buffer.onLimitReached = { signals.increment() }
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		#expect(buffer.append([1, 2, 3]))
		#expect(buffer.append([4, 5, 6]))
		#expect(!buffer.append([7]))
		#expect(buffer.reachedLimit)
		#expect(signals.value == 1)
		#expect(buffer.finishCapture() == [1, 2, 3, 4])

		// The next recording starts fresh and can signal again
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		#expect(!buffer.reachedLimit)
		buffer.append([1, 2, 3, 4, 5])
		#expect(signals.value == 2)
		#expect(buffer.finishCapture() == [1, 2, 3, 4])
	}

	@Test func defaultCapIsThirtyMinutes() {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		let minute = [Float](repeating: 0, count: 16000 * 60)
		for _ in 0..<StreamCaptureBuffer.maxMinutes {
			buffer.append(minute)
		}
		#expect(!buffer.reachedLimit)
		buffer.append([0])
		#expect(buffer.reachedLimit)
		#expect(buffer.finishCapture().count == 16000 * 60 * 30)
	}

	@Test func ingestKeepsSixteenKilohertzMonoUnchanged() {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		let input = monoBuffer([0.1, 0.2, 0.3])
		#expect(buffer.ingest(input, format: input.format) == [0.1, 0.2, 0.3])
		#expect(buffer.finishCapture() == [0.1, 0.2, 0.3])
	}

	@Test func ingestResamplesWithoutDuplicatingInput() {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		let frames = 4800
		for _ in 0..<10 {
			let input = monoBuffer([Float](repeating: 0.25, count: frames), sampleRate: 48000)
			_ = buffer.ingest(input, format: input.format)
		}
		// 10 x 4800 frames at 48 kHz is one second, so about 16000 samples; the
		// resampler may hold back a few for its filter, but never produce extra.
		let count = buffer.finishCapture().count
		#expect(count <= 16000)
		#expect(count > 15500)
	}

	@Test func ingestIgnoresAudioWhenIdle() {
		let buffer = StreamCaptureBuffer()
		let input = monoBuffer([0.1, 0.2])
		#expect(buffer.ingest(input, format: input.format) == nil)
		#expect(buffer.count == 0)
	}

	@Test func concurrentAppendAndFinishNeverLoseOrDuplicateSamples() async {
		let buffer = StreamCaptureBuffer()
		buffer.beginCapture(channelSelection: InputChannelSelection.mixAllChannels)
		let chunk = [Float](repeating: 1, count: 256)
		let (kept, drained) = await withTaskGroup(of: (Int, Int).self) { group in
			for _ in 0..<8 {
				group.addTask {
					var kept = 0
					for _ in 0..<500 where buffer.append(chunk) {
						kept += chunk.count
					}
					return (kept, 0)
				}
			}
			group.addTask {
				var drained = 0
				for _ in 0..<200 {
					drained += buffer.finishCapture().count
					buffer.setCapturing(true)
				}
				return (0, drained)
			}
			var totals = (0, 0)
			for await (kept, drained) in group {
				totals.0 += kept
				totals.1 += drained
			}
			return totals
		}
		#expect(drained + buffer.finishCapture().count == kept)
	}
}

struct MicStreamSuspensionTests {
	@Test func anyReasonSuspendsAndOnlyTheLastOneResumes() {
		var suspension = MicStreamSuspension()
		let r8 = suspension.begin(.screenLocked)
		#expect(r8)
		let r9 = suspension.begin(.displaySleep)
		#expect(!r9)
		#expect(suspension.isSuspended)
		let r10 = suspension.end(.screenLocked)
		#expect(!r10)
		#expect(suspension.isSuspended)
		let r11 = suspension.end(.displaySleep)
		#expect(r11)
		#expect(!suspension.isSuspended)
	}

	@Test func endingAnInactiveReasonDoesNothing() {
		var suspension = MicStreamSuspension()
		let r12 = suspension.end(.lowPowerMode)
		#expect(!r12)
	}

	@Test func wakeClearsSleepButNotLockOrLowPower() {
		var suspension = MicStreamSuspension()
		suspension.begin(.systemSleep)
		suspension.begin(.displaySleep)
		let r13 = suspension.endAfterWake()
		#expect(r13)
		suspension.begin(.systemSleep)
		suspension.begin(.screenLocked)
		let r14 = suspension.endAfterWake()
		#expect(!r14)
		#expect(suspension.reasons == [.screenLocked])
	}

	@Test(arguments: MicStreamPolicy.allCases)
	func keepingOpenNeedsAKeepOpenPolicyAndNoSuspension(policy: MicStreamPolicy) {
		var suspension = MicStreamSuspension()
		#expect(MicStreamSuspension.allowsKeepingOpen(policy: policy, suspension: suspension) == (policy != .onDemand))
		suspension.begin(.lowPowerMode)
		#expect(!MicStreamSuspension.allowsKeepingOpen(policy: policy, suspension: suspension))
	}

	@Test func keepOpenSummariesMentionTheirCost() {
		#expect(MicStreamPolicy.alwaysOn.summary.contains("battery"))
		#expect(MicStreamPolicy.alwaysOn.summary.contains("sleep"))
		#expect(MicStreamPolicy.lazyClose.summary.contains("indicator"))
	}
}

final class LockedCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	var value: Int { lock.withLock { count } }
	func increment() { lock.withLock { count += 1 } }
}
