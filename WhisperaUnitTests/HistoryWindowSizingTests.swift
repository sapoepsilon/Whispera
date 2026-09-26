import AppKit
import SwiftUI
import Testing

@testable import Whispera

@MainActor
struct HistoryWindowSizingTests {
	private struct TallList: View {
		var body: some View {
			List(0..<200, id: \.self) { row in
				Text("Entry \(row)")
			}
		}
	}

	/// Shaped like TranscriptionHistoryView: settings and a toolbar above an inset list of
	/// multi-line rows.
	private struct HistoryShapedView: View {
		@State private var query = ""
		var body: some View {
			VStack(spacing: 0) {
				VStack(alignment: .leading, spacing: 12) {
					Text("History").font(.headline)
					Toggle("Save transcription history", isOn: .constant(true))
					Toggle("Save recordings", isOn: .constant(false))
				}
				.padding(20)
				Divider()
				HStack {
					TextField("Search transcriptions", text: $query)
					Button("Clear") {}
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 10)
				List(0..<50, id: \.self) { row in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text("Sep 26 at 4:45 PM  0:05  Small")
							Spacer()
							Button("Copy") {}
						}
						Text("The quick brown fox jumps over the lazy dog, entry \(row).")
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
				.listStyle(.inset)
			}
		}
	}

	/// The installed build still opened the real history window at 640 x 2745 pt once it was on
	/// screen, so the size is checked after the window is shown and SwiftUI has laid it out.
	@Test func staysOnScreenOnceShown() {
		let window = HistoryWindowController.makeWindow(rootView: HistoryShapedView())
		window.orderFront(nil)
		defer { window.orderOut(nil) }
		RunLoop.main.run(until: Date().addingTimeInterval(0.5))
		window.layoutIfNeeded()
		let contentSize = window.contentRect(forFrameRect: window.frame).size
		#expect(contentSize.height <= HistoryWindowController.defaultContentSize.height)
		#expect(window.contentMinSize.height <= HistoryWindowController.defaultContentSize.height)
	}

	@Test func opensAtTheDefaultSize() {
		let window = HistoryWindowController.makeWindow(rootView: TallList())
		window.layoutIfNeeded()
		let contentSize = window.contentRect(forFrameRect: window.frame).size
		#expect(contentSize == HistoryWindowController.defaultContentSize)
	}

	/// The hosting view pushed the history list's full height onto the window (640 x 2745 pt with
	/// 50 entries), even as a minimum, running it off the bottom of the screen.
	@Test func theContentSetsNoWindowConstraints() throws {
		let window = HistoryWindowController.makeWindow(rootView: TallList())
		let hostingView = try #require(window.contentView as? NSHostingView<TallList>)
		#expect(hostingView.sizingOptions.isEmpty)
		#expect(window.contentMinSize == HistoryWindowController.minimumContentSize)
	}
}
