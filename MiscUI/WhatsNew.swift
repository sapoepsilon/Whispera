import AppKit
import MarkdownUI
import SwiftUI

struct WhatsNewTracker {
	static let enabledKey = "showWhatsNewOnUpdate"
	static let lastSeenVersionKey = "lastSeenAppVersion"
	static let onboardingKey = "hasCompletedOnboarding"

	let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	var isEnabled: Bool {
		get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
		nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
	}

	// Installs that predate this tracker have no recorded version; a finished onboarding
	// tells an upgrading user apart from a fresh install, which should not see the sheet.
	static func shouldShow(
		lastSeenVersion: String?, currentVersion: String, hasCompletedOnboarding: Bool,
		enabled: Bool
	) -> Bool {
		guard enabled else { return false }
		guard let lastSeenVersion else { return hasCompletedOnboarding }
		return AppVersion(currentVersion) > AppVersion(lastSeenVersion)
	}

	func evaluateLaunch(currentVersion: String) -> Bool {
		let show = Self.shouldShow(
			lastSeenVersion: defaults.string(forKey: Self.lastSeenVersionKey),
			currentVersion: currentVersion,
			hasCompletedOnboarding: defaults.bool(forKey: Self.onboardingKey),
			enabled: isEnabled
		)
		defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
		return show
	}
}

enum WhatsNewReleaseNotes {
	static func releaseURL(for version: String) -> URL? {
		URL(string: "https://api.github.com/repos/\(AppVersion.Constants.githubRepo)/releases/tags/v\(version)")
	}

	static func releasePageURL(for version: String) -> URL? {
		URL(string: "https://github.com/\(AppVersion.Constants.githubRepo)/releases/tag/v\(version)")
	}

	static func decodeBody(from data: Data) throws -> String {
		try JSONDecoder().decode(GitHubRelease.self, from: data).body
	}

	static func fetch(version: String, session: URLSession = .shared) async throws -> String {
		guard let url = releaseURL(for: version) else { throw UpdateError.invalidResponse }
		var request = URLRequest(url: url)
		request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await session.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.networkError }
		return try decodeBody(from: data)
	}
}

@MainActor
final class WhatsNewController {
	static let shared = WhatsNewController()

	private var window: NSWindow?

	private init() {}

	func checkOnLaunch(suppress: Bool = false, tracker: WhatsNewTracker = WhatsNewTracker()) {
		let version = AppVersion.Constants.currentVersionString
		guard tracker.evaluateLaunch(currentVersion: version), !suppress else { return }
		AppLogger.shared.general.info("Showing What's New for \(version)")
		show(version: version)
	}

	func show(version: String = AppVersion.Constants.currentVersionString) {
		window?.close()

		let view = WhatsNewView(version: version) { [weak self] in
			self?.window?.close()
			self?.window = nil
		}
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = String(localized: "What's New in Whispera")
		window.contentView = NSHostingView(rootView: view)
		window.isReleasedWhenClosed = false
		window.center()
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		self.window = window
	}
}

struct WhatsNewView: View {
	let version: String
	let onClose: () -> Void

	@AppStorage(WhatsNewTracker.enabledKey) private var showOnUpdate = true
	@State private var notes: String?
	@State private var loadFailed = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "sparkles")
					.font(.title)
					.foregroundColor(.accentColor)
				VStack(alignment: .leading, spacing: 2) {
					Text("What's New")
						.font(.title2)
						.fontWeight(.semibold)
					Text("Whispera \(version)")
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
				Spacer()
			}
			.padding(20)

			Divider()

			ScrollView {
				Group {
					if let notes {
						Markdown(notes)
					} else if loadFailed {
						VStack(alignment: .leading, spacing: 8) {
							Text("Release notes couldn't be loaded.")
							if let url = WhatsNewReleaseNotes.releasePageURL(for: version) {
								Link("View this release on GitHub", destination: url)
							}
						}
					} else {
						ProgressView()
							.frame(maxWidth: .infinity)
					}
				}
				.padding(20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			Divider()

			HStack {
				Toggle("Show after updates", isOn: $showOnUpdate)
					.toggleStyle(.checkbox)
				Spacer()
				Button("Continue", action: onClose)
					.keyboardShortcut(.defaultAction)
			}
			.padding(16)
		}
		.frame(minWidth: 460, minHeight: 420)
		.task {
			do {
				notes = try await WhatsNewReleaseNotes.fetch(version: version)
			} catch {
				AppLogger.shared.general.error("Failed to load release notes for \(version): \(error)")
				loadFailed = true
			}
		}
	}
}

struct WhatsNewSettingRow: View {
	@AppStorage(WhatsNewTracker.enabledKey) private var showOnUpdate = true

	var body: some View {
		SettingRow(
			"What's New After Updates",
			description: "Show release notes the first time a new version launches"
		) {
			HStack(spacing: 8) {
				Button("Show Now") {
					WhatsNewController.shared.show()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				Toggle("", isOn: $showOnUpdate)
			}
		}
	}
}
