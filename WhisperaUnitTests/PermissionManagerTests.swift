import AVFoundation
import Foundation
import Testing

@testable import Whispera

struct PermissionManagerTests {

	@Test func authorizedIsAlreadyGranted() {
		#expect(PermissionManager.microphoneAction(for: .authorized) == .alreadyGranted)
	}

	@Test func notDeterminedPromptsUser() {
		#expect(PermissionManager.microphoneAction(for: .notDetermined) == .promptUser)
	}

	@Test func deniedOpensSystemSettings() {
		#expect(PermissionManager.microphoneAction(for: .denied) == .openSystemSettings)
	}

	@Test func restrictedOpensSystemSettings() {
		#expect(PermissionManager.microphoneAction(for: .restricted) == .openSystemSettings)
	}
}
