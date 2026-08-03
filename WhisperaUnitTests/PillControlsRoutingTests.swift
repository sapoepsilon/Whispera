import Foundation
import Testing

@testable import Whispera

struct PillControlsRoutingTests {

	@Test func showWithPageHintRoundTrips() {
		let info = PillControlsRouting.userInfo(show: true, page: .input)
		#expect(PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .input)
	}

	@Test func showWithoutPageHintDefaultsToRoot() {
		let info = PillControlsRouting.userInfo(show: true)
		#expect(PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .root)
	}

	@Test func hidePayloadCarriesNoPage() {
		let info = PillControlsRouting.userInfo(show: false)
		#expect(!PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .root)
	}

	@Test func missingUserInfoIsHideOnRoot() {
		#expect(!PillControlsRouting.show(in: nil))
		#expect(PillControlsRouting.page(in: nil) == .root)
	}

	@Test func unknownPageHintDegradesToRoot() {
		let info: [AnyHashable: Any] = [
			PillControlsRouting.showKey: true,
			PillControlsRouting.pageKey: "definitely-not-a-page",
		]
		#expect(PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .root)
	}

	@Test func wrongValueTypesDegradeToHideOnRoot() {
		let info: [AnyHashable: Any] = [
			PillControlsRouting.showKey: "yes",
			PillControlsRouting.pageKey: 7,
		]
		#expect(!PillControlsRouting.show(in: info))
		#expect(PillControlsRouting.page(in: info) == .root)
	}

	// The payload crosses NotificationCenter, so the raw values are a wire
	// contract between the pill (poster) and ListeningWindow (host).
	@Test func pageRawValuesAreStable() {
		#expect(PillPage.root.rawValue == "root")
		#expect(PillPage.input.rawValue == "input")
		#expect(PillPage.action.rawValue == "action")
	}

	@Test func payloadSurvivesNotificationBridging() {
		let notification = Notification(
			name: .pillControlsToggled,
			object: nil,
			userInfo: PillControlsRouting.userInfo(show: true, page: .input)
		)
		#expect(PillControlsRouting.show(in: notification.userInfo))
		#expect(PillControlsRouting.page(in: notification.userInfo) == .input)
	}
}
