import Foundation
import Testing

@testable import Whispera

struct PillControlsStateTests {

	@Test func startsClosedOnRoot() {
		let state = PillControlsState()
		#expect(!state.isOpen)
		#expect(state.page == .root)
	}

	@Test func firstTapOpensThatPage() {
		var state = PillControlsState()
		state.tap(.input)
		#expect(state.isOpen)
		#expect(state.page == .input)
	}

	@Test func secondTapOnTheSameGlyphDismisses() {
		var state = PillControlsState()
		state.tap(.action)
		state.tap(.action)
		#expect(!state.isOpen)
	}

	@Test func tappingTheOtherGlyphSwapsPageWithoutClosing() {
		var state = PillControlsState()
		state.tap(.input)
		state.tap(.action)
		#expect(state.isOpen)
		#expect(state.page == .action)
	}

	@Test func reopeningLandsOnTheLastPage() {
		var state = PillControlsState()
		state.tap(.action)
		state.tap(.action)
		state.tap(.action)
		#expect(state.isOpen)
		#expect(state.page == .action)
	}

	@Test func externalDismissalClosesWithoutLosingThePage() {
		var state = PillControlsState()
		state.tap(.input)
		state.dismissed()
		#expect(!state.isOpen)
		#expect(state.page == .input)
	}

	@Test func dismissingTwiceIsHarmless() {
		var state = PillControlsState()
		state.tap(.input)
		state.dismissed()
		state.dismissed()
		#expect(!state.isOpen)
	}

	@Test func tappingAfterAnExternalDismissalReopensThatPage() {
		var state = PillControlsState()
		state.tap(.input)
		state.dismissed()
		state.tap(.input)
		#expect(state.isOpen)
		#expect(state.page == .input)
	}

	@Test func openPayloadCarriesTheRequestedPage() {
		var state = PillControlsState()
		state.tap(.action)
		let info = state.routingUserInfo
		#expect(PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .action)
	}

	@Test func closePayloadIsAHide() {
		var state = PillControlsState()
		state.tap(.input)
		state.tap(.input)
		let info = state.routingUserInfo
		#expect(!PillControlsRouting.show(in: info))
	}
}
