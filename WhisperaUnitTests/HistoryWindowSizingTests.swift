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

	@Test func opensAtTheDefaultSize() {
		let window = HistoryWindowController.makeWindow(rootView: TallList())
		window.layoutIfNeeded()
		let contentSize = window.contentRect(forFrameRect: window.frame).size
		#expect(contentSize == HistoryWindowController.defaultContentSize)
	}

	/// With the default sizing options the hosting view pushed the history list's full height
	/// onto the window (640 x 2745 pt with 50 entries), running it off the bottom of the screen.
	@Test func theContentOnlyConstrainsTheMinimumSize() throws {
		let window = HistoryWindowController.makeWindow(rootView: TallList())
		let hostingView = try #require(window.contentView as? NSHostingView<TallList>)
		#expect(hostingView.sizingOptions == [.minSize])
	}
}
