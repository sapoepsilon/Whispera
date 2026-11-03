import Foundation
import Testing

@testable import Whispera

struct SettingsRoutingTests {

	@Test func matchesNativeSettingsSceneIdentifiers() {
		#expect(AppDelegate.isSettingsSceneIdentifier("com_apple_SwiftUI_Settings"))
		#expect(AppDelegate.isSettingsSceneIdentifier("com_apple_SwiftUI_Settings-1-AppWindow"))
	}

	@Test func rejectsOtherWindowIdentifiers() {
		#expect(!AppDelegate.isSettingsSceneIdentifier(nil))
		#expect(!AppDelegate.isSettingsSceneIdentifier(""))
		#expect(!AppDelegate.isSettingsSceneIdentifier("NSWindow-1"))
		#expect(!AppDelegate.isSettingsSceneIdentifier("prefix-com_apple_SwiftUI_Settings"))
	}

	// The pill's floating panel opens Settings by posting this name; a rename
	// on either side silently breaks the "Add your own…" route.
	@Test func openSettingsRequestedNameIsStable() {
		#expect(Notification.Name.openSettingsRequested.rawValue == "OpenSettingsRequested")
	}

	@Test func recipesDestinationRoundTrips() {
		let info = SettingsRouting.userInfo(destination: .recipes)
		#expect(SettingsRouting.destination(in: info) == .recipes)
		#expect(SettingsRouting.destination(in: nil) == nil)
	}
}
