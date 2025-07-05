import XCTest
@testable import Whispera

final class VersionTests: XCTestCase {
    
    // MARK: - Version Comparison Tests
    
    func testVersionComparison() {
        // Test semantic version comparison
        XCTAssertTrue(AppVersion("1.0.1").isNewerThan("1.0.0"))
        XCTAssertTrue(AppVersion("1.1.0").isNewerThan("1.0.9"))
        XCTAssertTrue(AppVersion("2.0.0").isNewerThan("1.9.9"))
        XCTAssertFalse(AppVersion("1.0.0").isNewerThan("1.0.0"))
        XCTAssertFalse(AppVersion("1.0.0").isNewerThan("1.0.1"))
    }
    
    func testVersionEquality() {
        // Test version equality
        XCTAssertEqual(AppVersion("1.0.0"), AppVersion("1.0.0"))
        XCTAssertNotEqual(AppVersion("1.0.0"), AppVersion("1.0.1"))
    }
    
    func testVersionParsing() {
        // Test version string parsing
        let version = AppVersion("1.2.3")
        XCTAssertEqual(version.major, 1)
        XCTAssertEqual(version.minor, 2)
        XCTAssertEqual(version.patch, 3)
    }
    
    func testInvalidVersionHandling() {
        // Test handling of invalid version strings
        let invalidVersion = AppVersion("invalid")
        XCTAssertEqual(invalidVersion.major, 0)
        XCTAssertEqual(invalidVersion.minor, 0)
        XCTAssertEqual(invalidVersion.patch, 0)
    }
    
    func testCurrentAppVersion() {
        // Test that current app version is accessible
        let currentVersion = AppVersion.current
        XCTAssertNotNil(currentVersion)
        XCTAssertFalse(currentVersion.versionString.isEmpty)
    }
    
    func testVersionFromBundle() {
        // Test reading version from bundle
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertNotNil(bundleVersion)
        
        let appVersion = AppVersion.current
        XCTAssertEqual(appVersion.versionString, bundleVersion)
    }
}

// MARK: - Version Model (to be implemented)

struct AppVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let versionString: String
    
    init(_ versionString: String) {
        self.versionString = versionString
        
        let components = versionString.split(separator: ".").compactMap { Int($0) }
        self.major = components.count > 0 ? components[0] : 0
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }
    
    static var current: AppVersion {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return AppVersion(version)
    }
    
    func isNewerThan(_ other: String) -> Bool {
        return self > AppVersion(other)
    }
    
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
    
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}