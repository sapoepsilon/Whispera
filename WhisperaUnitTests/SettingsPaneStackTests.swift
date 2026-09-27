import AppKit
import SwiftUI
import Testing

@testable import Whispera

/// Settings panes used to live in a TabView, which kept each tab's state; the sidebar must too,
/// or a running benchmark, a History search or an unsaved API key is lost on every row switch.
@MainActor
struct SettingsPaneStackTests {
	final class Log {
		var created: [SettingsPane: Int] = [:]
		var active: [SettingsPane: Bool] = [:]
	}

	final class PaneState: ObservableObject {
		init(pane: SettingsPane, log: Log) {
			log.created[pane, default: 0] += 1
		}
	}

	struct ProbePane: View {
		let pane: SettingsPane
		let log: Log
		@StateObject private var state: PaneState
		@Environment(\.settingsPaneIsActive) private var isActive

		init(pane: SettingsPane, log: Log) {
			self.pane = pane
			self.log = log
			_state = StateObject(wrappedValue: PaneState(pane: pane, log: log))
		}

		var body: some View {
			log.active[pane] = isActive
			return Text(pane.rawValue)
		}
	}

	final class Selection: ObservableObject {
		@Published var current: SettingsPane
		@Published var visible: [SettingsPane]

		init(current: SettingsPane, visible: [SettingsPane]) {
			self.current = current
			self.visible = visible
		}
	}

	struct Harness: View {
		@ObservedObject var selection: Selection
		let log: Log

		var body: some View {
			SettingsPaneStack(visible: selection.visible, current: selection.current) { pane in
				ProbePane(pane: pane, log: log)
			}
		}
	}

	private let log = Log()
	private let selection = Selection(
		current: .benchmark, visible: SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: true))
	private let window = NSWindow(
		contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
		defer: false)

	init() {
		window.isReleasedWhenClosed = false
		window.contentView = NSHostingView(rootView: Harness(selection: selection, log: log))
		settle()
	}

	private func settle() {
		for _ in 0..<10 {
			window.contentView?.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: Date().addingTimeInterval(0.02))
		}
	}

	private func show(_ pane: SettingsPane) {
		selection.current = pane
		settle()
	}

	@Test func onlyTheSelectedPaneIsBuiltAtFirst() {
		#expect(log.created == [.benchmark: 1])
		#expect(log.active[.benchmark] == true)
	}

	@Test func switchingAwayAndBackKeepsThePaneState() {
		show(.general)
		show(.history)
		show(.benchmark)
		#expect(log.created[.benchmark] == 1, "the benchmark pane was rebuilt and lost its runner")
		#expect(log.created[.general] == 1)
		#expect(log.created[.history] == 1)
	}

	@Test func onlyTheSelectedPaneIsActive() {
		show(.general)
		#expect(log.active[.general] == true)
		#expect(log.active[.benchmark] == false)
		show(.benchmark)
		#expect(log.active[.benchmark] == true)
		#expect(log.active[.general] == false)
	}

	@Test func aHiddenPaneIsDroppedAndStartsFreshWhenShownAgain() {
		show(.debug)
		show(.general)
		selection.visible = SettingsPane.visible(debugModeEnabled: false, liveTranscriptionEnabled: true)
		settle()
		selection.visible = SettingsPane.visible(debugModeEnabled: true, liveTranscriptionEnabled: true)
		settle()
		#expect(log.created[.debug] == 1, "a re-shown pane should not be rebuilt until it is opened")
		show(.debug)
		#expect(log.created[.debug] == 2)
	}
}

@MainActor
struct BenchmarkRunnerConcurrencyTests {
	/// The Run button is disabled while a benchmark runs, and the runner itself refuses a second
	/// run so an old pane cannot start one alongside the first.
	@Test func aSecondRunIsRefusedWhileOneIsInProgress() async {
		let runner = BenchmarkRunner()
		runner.isRunning = true
		let summary = await runner.runBenchmark(audioFiles: [URL(fileURLWithPath: "/tmp/does-not-matter.wav")])
		#expect(summary == nil)
		#expect(runner.isRunning)
		#expect(runner.error == nil)
	}
}
