import XCTest

final class SimpleTest: XCTestCase {

	func testBasicFunctionality() {
		// This test should pass - just testing that our test infrastructure works
		XCTAssertTrue(true, "Basic test should pass")
	}

	func testUserDefaultsAccess() {
		// Test that we can access UserDefaults
		UserDefaults.standard.set("test", forKey: "testKey")
		let value = UserDefaults.standard.string(forKey: "testKey")
		XCTAssertEqual(value, "test", "Should be able to read/write UserDefaults")

		// Clean up
		UserDefaults.standard.removeObject(forKey: "testKey")
	}
}
