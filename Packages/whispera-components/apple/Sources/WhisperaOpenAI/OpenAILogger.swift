import Foundation

public enum OpenAILogLevel: String, Sendable, Equatable {
	case info
	case error
}

/// Scrubs secrets out of anything this package is about to hand a host to log.
///
/// A key should never reach a log line, but "remember not to interpolate it"
/// is not a rule a package can enforce on itself either — so every message
/// leaving this package goes through here first, and a host that wants a
/// stricter rule passes its own closure.
public enum OpenAIRedactor {
	private static let patterns: [NSRegularExpression] = {
		[
			"sk-[A-Za-z0-9-_]{20,}",
			"(?i)(bearer)\\s+[A-Za-z0-9-._~+/]{8,}",
			"(?i)([?&](?:api[-_]?key|token|access_token)=)[^&\\s]+",
		].compactMap { try? NSRegularExpression(pattern: $0) }
	}()

	private static let templates = ["sk-***REDACTED***", "$1 ***REDACTED***", "$1***REDACTED***"]

	/// The default rule: provider keys, bearer tokens, and credential-bearing
	/// query parameters.
	public static let redactSecrets: @Sendable (String) -> String = { redact($0) }

	private static func redact(_ message: String) -> String {
		var result = message
		for (pattern, template) in zip(patterns, templates) {
			let range = NSRange(result.startIndex..., in: result)
			result = pattern.stringByReplacingMatches(
				in: result, range: range, withTemplate: template)
		}
		return result
	}

	/// For a host that would rather log nothing than risk a rule being wrong.
	public static let dropEverything: @Sendable (String) -> String = { _ in "***" }
}

/// Where this package's diagnostics go, and what is stripped from them first.
///
/// A closure rather than a protocol with an implementation, because the one
/// thing the package must not do is pick a logging backend for its host — and
/// the one thing it must do is redact before handing anything over.
public struct OpenAILogger: Sendable {
	private let emit: @Sendable (OpenAILogLevel, String) -> Void
	private let redactor: @Sendable (String) -> String

	public init(
		redact: @escaping @Sendable (String) -> String = OpenAIRedactor.redactSecrets,
		emit: @escaping @Sendable (OpenAILogLevel, String) -> Void
	) {
		self.redactor = redact
		self.emit = emit
	}

	/// The default: nothing is logged, and nothing can therefore leak.
	public static let none = OpenAILogger { _, _ in }

	public func redact(_ message: String) -> String { redactor(message) }

	public func info(_ message: @autoclosure () -> String) {
		emit(.info, redactor(message()))
	}

	public func error(_ message: @autoclosure () -> String) {
		emit(.error, redactor(message()))
	}
}
