import XCTest

@testable import LinkHelperCore

/// §7.1 / §8: the helper accepts only bytes that are already the broker's canonical form.
final class ApprovalCanonicalTests: XCTestCase {
	/// `docs/vectors/v1.json` → `approval.canonical_b64` (whispera-link).
	static let vectorB64 =
		"eyJicm9rZXIiOiJBbGljZSdzIE1hY0Jvb2sgXHUyMDE0IHRlc3QiLCJjYWxsZXIiOiJjbGF1ZGUgbWNwIiwiY3JlYXRlZF9hdCI6MTc5MTE1ODQwMCwiZXhwaXJlc19hdCI6MTc5MTE1ODUwMCwiaG9zdCI6ImJ1aWxkLWJveCIsImtleSI6IiIsIm5vbmNlIjoiWm05dlltRnlZbUY2Y1hWNE1USXpOQSIsIm9wIjoiYndzIiwicHJvamVjdCI6IiIsInJlcXVlc3RfaWQiOiJhcHJfYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwic3VtbWFyeSI6InJlYWQgc2VjcmV0IDNmMWMyYTliXHUyMDI2IiwidG9rZW4iOiJyZWFkIiwidiI6MSwidmlhIjoic3NoIHNlc3Npb24gdG8gYnVpbGQtYm94In0="

	func testVectorIsAcceptedAndReserialisesByteForByte() throws {
		let (raw, fields) = try ApprovalsServer.parseCanonical(Self.vectorB64)
		XCTAssertEqual(raw, Data(base64Encoded: Self.vectorB64))
		XCTAssertEqual(fields["broker"] as? String, "Alice's MacBook \u{2014} test")
		XCTAssertEqual(fields["expires_at"] as? Int, 1_791_158_500)
	}

	func testNonCanonicalVariantsAreMalformed() throws {
		let raw = String(decoding: Data(base64Encoded: Self.vectorB64)!, as: UTF8.self)
		let variants = [
			raw.replacingOccurrences(of: "\"v\":1", with: "\"v\": 1"),
			raw.replacingOccurrences(of: "\"v\":1", with: "\"v\":true"),
			raw.replacingOccurrences(of: "\"v\":1", with: "\"v\":1.0"),
			raw.replacingOccurrences(of: "\\u2014", with: "\u{2014}"),
			raw.replacingOccurrences(of: "\"via\":", with: "\"extra\":\"x\",\"via\":"),
			raw.replacingOccurrences(of: "\"op\":\"bws\"", with: "\"op\":\"run\""),
			raw.replacingOccurrences(of: "1791158500", with: "1791158400"),
		]
		for variant in variants {
			XCTAssertThrowsError(
				try ApprovalsServer.parseCanonical(Data(variant.utf8).base64EncodedString()), variant)
		}
	}
}
