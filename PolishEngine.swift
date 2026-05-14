// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import SwiftUI

enum PolishSettings {
	private static let serverURLKey = "whisperaServerURL"
	private static let devTokenKey = "whisperaDevToken"

	static var serverURL: String {
		get { UserDefaults.standard.string(forKey: serverURLKey) ?? "http://localhost:3000" }
		set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
	}

	static var devToken: String {
		get { UserDefaults.standard.string(forKey: devTokenKey) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: devTokenKey) }
	}
}

enum PolishError: LocalizedError {
	case invalidURL
	case missingToken
	case http(status: Int, body: String)
	case decoding(Error)
	case transport(Error)
	case empty

	var errorDescription: String? {
		switch self {
		case .invalidURL: return "Invalid Whispera server URL"
		case .missingToken: return "No auth token configured"
		case .http(let status, let body): return "HTTP \(status): \(body)"
		case .decoding(let err): return "Decoding failed: \(err.localizedDescription)"
		case .transport(let err): return "Network error: \(err.localizedDescription)"
		case .empty: return "Server returned empty result"
		}
	}
}

private struct PolishRequest: Encodable {
	let text: String
}

private struct PolishResponse: Decodable {
	let polished: String
}

@MainActor
@Observable
final class PolishService {
	private(set) var isRunning = false
	private(set) var lastError: String?

	private let session: URLSession
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()

	init(session: URLSession = .shared) {
		self.session = session
	}

	/// Falls back to the original input on any error so the user always
	/// gets something in their cursor.
	func polish(_ text: String) async -> String {
		guard !PolishSettings.devToken.isEmpty,
		      let base = URL(string: PolishSettings.serverURL)
		else {
			return text
		}

		isRunning = true
		lastError = nil
		defer { isRunning = false }

		do {
			var req = URLRequest(url: base.appendingPathComponent("/polish"))
			req.httpMethod = "POST"
			req.setValue("Bearer \(PolishSettings.devToken)", forHTTPHeaderField: "Authorization")
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
			req.setValue("application/json", forHTTPHeaderField: "Accept")
			req.httpBody = try encoder.encode(PolishRequest(text: text))

			let (data, response) = try await session.data(for: req)
			guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
				let status = (response as? HTTPURLResponse)?.statusCode ?? -1
				let body = String(data: data, encoding: .utf8) ?? ""
				throw PolishError.http(status: status, body: body)
			}

			let decoded = try decoder.decode(PolishResponse.self, from: data)
			guard !decoded.polished.isEmpty else { throw PolishError.empty }
			return decoded.polished
		} catch is CancellationError {
			return text
		} catch {
			lastError = error.localizedDescription
			AppLogger.shared.network.error(
				"PolishService: failed — \(error.localizedDescription)")
			return text
		}
	}
}
