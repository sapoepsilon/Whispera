import Foundation

// MARK: - Bundle Extension for Version Access

extension Bundle {
	/// App version number (CFBundleShortVersionString)
	var releaseVersionNumber: String? {
		return infoDictionary?["CFBundleShortVersionString"] as? String
	}

	/// Build number (CFBundleVersion)
	var buildVersionNumber: String? {
		return infoDictionary?["CFBundleVersion"] as? String
	}
}

/// Represents a semantic version (major.minor.patch)
struct AppVersion: Equatable, Comparable, Codable {
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

	/// Current app version from bundle (dynamic)
	static var current: AppVersion {
		let version = Bundle.main.releaseVersionNumber ?? "1.0.0"
		return AppVersion(version)
	}

	/// Current build number from bundle
	static var currentBuild: String {
		return Bundle.main.buildVersionNumber ?? "1"
	}

	/// Formatted version string for display
	var displayString: String {
		return "v\(versionString)"
	}

	/// Check if this version is newer than another version string
	func isNewerThan(_ other: String) -> Bool {
		return self > AppVersion(other)
	}

	// MARK: - Comparable

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

// MARK: - Version Constants

extension AppVersion {
	/// Centralized constants for app configuration
	struct Constants {
		/// Minimum supported macOS version
		static let minimumMacOS = "13.0"

		/// GitHub repository for updates
		static let githubRepo = "sapoepsilon/Whispera"

		/// Update check URL
		static let updateURL = "https://api.github.com/repos/\(githubRepo)/releases/latest"

		/// Current app version string (dynamically retrieved)
		static var currentVersionString: String {
			return AppVersion.current.versionString
		}

		/// Current build number (dynamically retrieved)
		static var currentBuildString: String {
			return AppVersion.currentBuild
		}
	}
}
