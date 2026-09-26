import Foundation
import Security

enum UpdateSignatureError: LocalizedError, Equatable {
	case unreadable(OSStatus)
	case invalidSignature(OSStatus)

	var errorDescription: String? {
		switch self {
		case .unreadable(let status):
			return "The update's code signature could not be read (\(status))"
		case .invalidSignature(let status):
			return "The update is not signed by Whispera's developer (\(status))"
		}
	}
}

/// Checks that an app bundle about to replace Whispera is signed with Whispera's Developer ID,
/// so a disk image planted in ~/Downloads or swapped in transit can never be installed.
enum UpdateSignatureVerifier {
	static let teamIdentifier = "NK28QT38A3"
	static let bundleIdentifier = "com.macwhisper.app"

	/// Apple's designated requirement for Developer ID apps, pinned to this team and bundle.
	static let requirement =
		"anchor apple generic and identifier \"\(bundleIdentifier)\""
		+ " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
		+ " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
		+ " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

	static func verify(appAt url: URL, requirement text: String = requirement) throws {
		var staticCode: SecStaticCode?
		let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
		guard createStatus == errSecSuccess, let staticCode else {
			throw UpdateSignatureError.unreadable(createStatus)
		}
		var secRequirement: SecRequirement?
		let requirementStatus = SecRequirementCreateWithString(text as CFString, [], &secRequirement)
		guard requirementStatus == errSecSuccess, let secRequirement else {
			throw UpdateSignatureError.unreadable(requirementStatus)
		}
		let flags = SecCSFlags(
			rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
		let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, secRequirement, nil)
		guard status == errSecSuccess else { throw UpdateSignatureError.invalidSignature(status) }
	}
}
