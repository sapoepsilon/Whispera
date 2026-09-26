import Foundation

#if canImport(FoundationModels)
	import FoundationModels
#endif

enum AppleIntelligenceAvailability: Equatable, Sendable {
	case available
	case unavailable(String)

	var isAvailable: Bool { self == .available }

	var summary: String {
		switch self {
		case .available: return String(localized: "Available")
		case .unavailable(let reason): return reason
		}
	}
}

/// On-device post-processing through the FoundationModels system model (macOS 26+, Apple Silicon,
/// Apple Intelligence turned on). FoundationModels is weak-linked, so every entry point is gated.
struct AppleIntelligenceProcessor: TextPostProcessor {
	static func availability() -> AppleIntelligenceAvailability {
		#if canImport(FoundationModels)
			if #available(macOS 26.0, *) {
				switch SystemLanguageModel.default.availability {
				case .available:
					return .available
				case .unavailable(.deviceNotEligible):
					return .unavailable(String(localized: "This Mac does not support Apple Intelligence"))
				case .unavailable(.appleIntelligenceNotEnabled):
					return .unavailable(String(localized: "Turn on Apple Intelligence in System Settings"))
				case .unavailable(.modelNotReady):
					return .unavailable(String(localized: "The on-device model is still downloading"))
				case .unavailable:
					return .unavailable(String(localized: "The on-device model is unavailable"))
				}
			}
			return .unavailable(String(localized: "Requires macOS 26 or later"))
		#else
			return .unavailable(String(localized: "This build was compiled without FoundationModels"))
		#endif
	}

	func process(_ messages: PostProcessingMessages) async throws -> String {
		let availability = Self.availability()
		guard availability.isAvailable else {
			throw PostProcessingError.appleIntelligenceUnavailable(reason: availability.summary)
		}
		#if canImport(FoundationModels)
			if #available(macOS 26.0, *) {
				let session: LanguageModelSession
				if let system = messages.system {
					session = LanguageModelSession(instructions: system)
				} else {
					session = LanguageModelSession()
				}
				let response = try await session.respond(to: messages.user)
				let cleaned = PostProcessingText.cleanModelOutput(response.content)
				guard !cleaned.isEmpty else { throw PostProcessingError.emptyResponse }
				return cleaned
			}
		#endif
		throw PostProcessingError.appleIntelligenceUnavailable(reason: availability.summary)
	}
}
