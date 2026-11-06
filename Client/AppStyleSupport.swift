// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import Foundation
import WhisperaRecipes

typealias AppCategory = WhisperaRecipes.AppCategory
typealias DictationStyle = WhisperaRecipes.DictationStyle
typealias AppStyleSettings = WhisperaRecipes.AppStyleSettings
typealias DictationAppContext = WhisperaRecipes.DictationAppContext
typealias AppCategoryResolver = WhisperaRecipes.AppCategoryResolver
typealias AppCategoryCatalog = WhisperaRecipes.AppCategoryCatalog
typealias AppStyleComposer = WhisperaRecipes.AppStyleComposer
typealias AppStyleApplication = WhisperaRecipes.AppStyleApplication
typealias AppStyleSettingsStore = WhisperaRecipes.AppStyleSettingsStore
typealias StyleFragment = WhisperaRecipes.StyleFragment

enum FrontmostAppContext {
	/// The app the user is dictating into, read when recording starts. NSWorkspace's frontmost
	/// app needs no permission. Whispera itself (Settings "Try it") counts as unknown.
	@MainActor
	static func capture(
		frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
		ownBundleID: String? = Bundle.main.bundleIdentifier
	) -> DictationAppContext {
		let bundleID = frontmost?.bundleIdentifier
		guard let bundleID, bundleID != ownBundleID else {
			return DictationAppContext(bundleID: nil, platform: .mac)
		}
		return DictationAppContext(bundleID: bundleID, appName: frontmost?.localizedName, platform: .mac)
	}
}

extension AppCategory {
	var displayName: String {
		switch self {
		case .personal: return String(localized: "Personal messages")
		case .work: return String(localized: "Work messages")
		case .email: return String(localized: "Email")
		case .code: return String(localized: "Code")
		case .other: return String(localized: "Everything else")
		}
	}

	var systemImage: String {
		switch self {
		case .personal: return "message"
		case .work: return "bubble.left.and.bubble.right"
		case .email: return "envelope"
		case .code: return "chevron.left.forwardslash.chevron.right"
		case .other: return "doc.text"
		}
	}
}

extension DictationStyle {
	var displayName: String {
		switch self {
		case .formal: return String(localized: "Formal")
		case .casual: return String(localized: "Casual")
		case .veryCasual: return String(localized: "Very casual")
		case .excited: return String(localized: "Excited")
		case .verbatim: return String(localized: "Unchanged")
		}
	}
}

/// The settings screen's view of `app-styles.json`. The coordinator reads the file itself on
/// every dictation, so the link helper and the app never disagree about what is saved.
@MainActor
@Observable
final class AppStyleSettingsModel {
	static let shared = AppStyleSettingsModel()

	private(set) var settings: AppStyleSettings
	@ObservationIgnored private let store: AppStyleSettingsStore

	init(store: AppStyleSettingsStore = AppStyleSettingsStore()) {
		self.store = store
		self.settings = store.load()
	}

	func reload() { settings = store.load() }

	/// Applies a change and saves it; throws when the file could not be written.
	func update(_ change: (inout AppStyleSettings) -> Void) throws {
		var next = settings
		change(&next)
		guard next != settings else { return }
		try store.save(next)
		settings = next
	}
}
