import Foundation
import Observation
import Testing

@testable import Whispera

struct DictationLedgerTranscriptionCancelTests {
	/// "Cancel Transcription" pressed while a newer dictation records must leave that recording alone.
	@Test func cancellingTranscriptionsKeepsTheRunningCapture() {
		var ledger = DictationSessionLedger()
		let (first, _) = ledger.beginCapture(mode: .text, postProcess: false)
		ledger.finishCapture()
		let (second, _) = ledger.beginCapture(mode: .text, postProcess: false)

		let cancelled = ledger.cancelTranscriptions()

		#expect(cancelled == [first])
		#expect(ledger.isCancelled(first.id))
		#expect(ledger.isCapturing(second.id))
		#expect(!ledger.isCancelled(second.id))
		#expect(!ledger.isTranscribing)
	}

	@Test func plainCancelStillTargetsTheCaptureFirst() {
		var ledger = DictationSessionLedger()
		let (first, _) = ledger.beginCapture(mode: .text, postProcess: false)
		ledger.finishCapture()
		let (second, _) = ledger.beginCapture(mode: .text, postProcess: false)

		#expect(ledger.cancel() == [second])
		#expect(ledger.isTranscribing(first.id))
	}
}

struct RecordButtonModeTests {
	@Test(arguments: [
		(false, false, RecordButtonMode.start),
		(true, false, RecordButtonMode.stop),
		(false, true, RecordButtonMode.transcribing),
		// A new recording while the previous one transcribes must still be stoppable
		(true, true, RecordButtonMode.stop),
	])
	func modeFollowsTheCaptureFirst(capturing: Bool, transcribing: Bool, expected: RecordButtonMode) {
		#expect(RecordButtonMode.resolve(capturing: capturing, transcribing: transcribing) == expected)
	}

	@Test func stopIsNeverBlocked() {
		#expect(RecordButtonMode.stop.isEnabled(blocked: true))
		#expect(!RecordButtonMode.start.isEnabled(blocked: true))
		#expect(RecordButtonMode.start.isEnabled(blocked: false))
		#expect(!RecordButtonMode.transcribing.isEnabled(blocked: false))
	}
}

struct MenuBarStatusPhaseTests {
	private func phase(
		downloadingFile: Bool = false, transcribingFile: Bool = false, needsPermissions: Bool = false,
		recording: Bool = false, downloadingModel: Bool = false, transcribing: Bool = false
	) -> MenuBarStatusPhase {
		MenuBarStatusPhase.resolve(
			downloadingFile: downloadingFile, transcribingFile: transcribingFile,
			needsPermissions: needsPermissions, recording: recording, downloadingModel: downloadingModel,
			transcribing: transcribing)
	}

	@Test func recordingOutranksAnEarlierTranscription() {
		#expect(phase(recording: true, transcribing: true) == .recording)
		#expect(phase(transcribing: true) == .transcribing)
		#expect(phase(recording: true, downloadingModel: true) == .recording)
	}

	@Test func fileWorkAndPermissionsStayOnTop() {
		#expect(phase(downloadingFile: true, recording: true) == .downloadingFile)
		#expect(phase(transcribingFile: true, recording: true) == .transcribingFile)
		#expect(phase(needsPermissions: true, recording: true) == .needsPermissions)
		#expect(phase() == .ready)
	}
}

@MainActor
struct ToastNotificationTests {
	@Test func routineNoticesDoNotPostASystemNotification() {
		let center = ToastCenter()
		var delivered: [String] = []
		center.isPopoverVisible = { false }
		center.deliverSystemNotification = { delivered.append($0.message) }

		center.show("No speech detected", type: .error, notifyWhenHidden: false)
		#expect(delivered.isEmpty)
		#expect(center.current?.message == "No speech detected")

		center.show("Transcription failed", type: .error)
		#expect(delivered == ["Transcription failed"])
	}

	@Test func nothingIsPostedWhileThePopoverIsOpen() {
		let center = ToastCenter()
		var delivered = 0
		center.isPopoverVisible = { true }
		center.deliverSystemNotification = { _ in delivered += 1 }
		center.show("Transcription failed", type: .error)
		#expect(delivered == 0)
	}
}

@MainActor
struct DictationNoticeTests {
	@Test func noticesAreMarkedRoutineAndErrorsAreNot() {
		let manager = AudioManager()
		manager.postNotice("No speech detected")
		#expect(manager.transcriptionError == "No speech detected")
		#expect(manager.transcriptionErrorIsNotice)

		manager.transcriptionError = "Transcription failed"
		#expect(!manager.transcriptionErrorIsNotice)

		manager.postNotice("Recording stopped early")
		manager.transcriptionError = nil
		#expect(!manager.transcriptionErrorIsNotice)
	}

	/// The microphone-loss notice is posted for users whose overlay cannot show it, so it has to
	/// reach them as a system notification when the menu bar is closed; routine notices do not.
	@Test func onlyFailuresAndNotifyingNoticesNotifyWhenHidden() {
		let manager = AudioManager()
		manager.postNotice("No speech detected")
		#expect(!manager.transcriptionErrorNotifiesWhenHidden)

		manager.postNotice("USB Mic disconnected", notifyWhenHidden: true)
		#expect(manager.transcriptionErrorIsNotice)
		#expect(manager.transcriptionErrorNotifiesWhenHidden)

		manager.transcriptionError = "Transcription failed"
		#expect(manager.transcriptionErrorNotifiesWhenHidden)

		manager.postNotice("Recording stopped early")
		#expect(!manager.transcriptionErrorNotifiesWhenHidden, "The notifying flag leaked into the next notice")

		manager.transcriptionError = nil
		#expect(!manager.transcriptionErrorNotifiesWhenHidden)
	}

	@Test func cancelTranscriptionsWithNothingInFlightIsANoOp() {
		let manager = AudioManager()
		manager.cancelTranscriptions()
		#expect(manager.currentState == .idle)
		#expect(!manager.isTranscribing)
	}
}

@MainActor
struct ObservedDefaultsFlagTests {
	private func makeDefaults() -> UserDefaults {
		let name = "ObservedDefaultsFlagTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		return defaults
	}

	/// The popover's Text/Translate control used to miss changes made in Settings.
	@Test func writesFromElsewhereInvalidateObservers() {
		let defaults = makeDefaults()
		let flag = ObservedDefaultsFlag(key: "enableTranslation", defaultValue: false, defaults: defaults)
		#expect(!flag.value)

		var changed = false
		withObservationTracking {
			_ = flag.value
		} onChange: {
			changed = true
		}
		defaults.set(true, forKey: "enableTranslation")

		#expect(changed)
		#expect(flag.value)
	}

	@Test func settingItWritesTheDefault() {
		let defaults = makeDefaults()
		let flag = ObservedDefaultsFlag(key: "enableTranslation", defaultValue: false, defaults: defaults)
		flag.set(true)
		#expect(defaults.bool(forKey: "enableTranslation"))
		#expect(flag.value)
	}

	@Test func unchangedWritesDoNotInvalidate() {
		let defaults = makeDefaults()
		defaults.set(true, forKey: "enableTranslation")
		let flag = ObservedDefaultsFlag(key: "enableTranslation", defaultValue: false, defaults: defaults)

		var changed = false
		withObservationTracking {
			_ = flag.value
		} onChange: {
			changed = true
		}
		defaults.set(true, forKey: "enableTranslation")
		#expect(!changed)
	}
}
