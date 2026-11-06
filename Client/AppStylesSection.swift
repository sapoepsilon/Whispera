// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Recipes → Styles: one style per app category, and which apps are in each.
struct AppStylesSection: View {
	@State private var model = AppStyleSettingsModel.shared
	@State private var alert: AppStylesAlert?
	@AppStorage(WhisperaSettings.recipesEnabledKey) private var recipesEnabled = false
	@AppStorage(CleanUpSettings.Key.onRequestEnabled) private var cleanUpOnRequest = false
	@AppStorage(WhisperaSettings.defaultCommandIdKey) private var defaultCommandId = ""

	var body: some View {
		Section {
			Toggle(isOn: binding(\.enabled)) {
				VStack(alignment: .leading, spacing: 2) {
					Text("Match style to the app you're dictating into")
					Text("Clean up formats a message for Slack differently from an email or a terminal.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.toggleStyle(.switch)
			.accessibilityIdentifier("appStylesToggle")
			if model.settings.enabled {
				ForEach(AppCategory.allCases, id: \.self) { category in
					categoryRow(category)
				}
			}
		} header: {
			Text("Styles")
		} footer: {
			VStack(alignment: .leading, spacing: 4) {
				Text("Styles change capitalization and punctuation only. They apply when Clean up runs.")
				if model.settings.enabled && !cleanUpWillRun {
					Text("Clean up isn't set to run: turn on its shortcut or make it the recipe that runs on every dictation.")
						.foregroundStyle(.orange)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
		}
		.onAppear { model.reload() }
		.alert(
			alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
			presenting: alert
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { alert in
			Text(alert.message)
		}
	}

	private var cleanUpWillRun: Bool {
		cleanUpOnRequest || (recipesEnabled && defaultCommandId == CleanUpRecipe.id)
			|| RecipeStore.shared.recipes.contains { $0.applyAppStyle }
	}

	private func categoryRow(_ category: AppCategory) -> some View {
		let builtIn = AppCategoryCatalog.entries(in: category, platform: .mac)
		let style = model.settings.style(for: category)
		return VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline) {
				Label(category.displayName, systemImage: category.systemImage)
				Spacer()
				Picker(category.displayName, selection: styleBinding(category)) {
					ForEach(DictationStyle.allowed(in: category), id: \.self) { style in
						Text(style.displayName).tag(style)
					}
				}
				.labelsHidden()
				.pickerStyle(.segmented)
				.fixedSize()
				.accessibilityIdentifier("appStylePicker.\(category.rawValue)")
			}
			Text(examplesLine(category, builtIn: builtIn))
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(verbatim: StyleFragment.example(style))
				.font(.callout.italic())
				.foregroundStyle(.secondary)
			DisclosureGroup("Apps") {
				appsList(category, builtIn: builtIn)
			}
			.font(.caption)
		}
		.padding(.vertical, 2)
	}

	private func examplesLine(_ category: AppCategory, builtIn: [AppCategoryCatalog.Entry]) -> String {
		if category == .other { return String(localized: "Notes, Pages, browsers and any app not listed elsewhere") }
		var seen = Set<String>()
		let names = builtIn.map(\.name).filter { seen.insert($0).inserted }.prefix(3)
		return names.joined(separator: ", ")
	}

	@ViewBuilder
	private func appsList(_ category: AppCategory, builtIn: [AppCategoryCatalog.Entry]) -> some View {
		let moved = model.settings.overrides.filter { $0.value == category }.keys.sorted()
		VStack(alignment: .leading, spacing: 4) {
			ForEach(moved, id: \.self) { bundleID in
				HStack {
					Text(verbatim: displayName(for: bundleID))
					Text(verbatim: bundleID).foregroundStyle(.tertiary)
					Spacer()
					Button {
						save { $0.setOverride(bundleID, to: nil) }
					} label: {
						Image(systemName: "minus.circle")
					}
					.buttonStyle(.borderless)
					.help("Remove")
				}
			}
			ForEach(builtIn, id: \.bundleID) { entry in
				let movedAway = model.settings.overrides[entry.bundleID.lowercased()].map { $0 != category } ?? false
				HStack {
					Text(verbatim: entry.name)
					if movedAway { Text("moved").foregroundStyle(.tertiary) }
				}
				.foregroundStyle(.secondary)
				.opacity(movedAway ? 0.5 : 0.8)
			}
			if category == .code {
				Text("JetBrains IDEs and Android Studio").foregroundStyle(.secondary).opacity(0.8)
			}
			addAppMenu(category)
		}
		.padding(.top, 4)
	}

	private func addAppMenu(_ category: AppCategory) -> some View {
		Menu("Add app…") {
			ForEach(runningApps(), id: \.bundleID) { app in
				Button(app.name) { add(app.bundleID, to: category) }
			}
			Divider()
			Button("Choose from Applications…") { chooseApp(for: category) }
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.accessibilityIdentifier("appStyleAddApp.\(category.rawValue)")
	}

	private struct RunningApp {
		let bundleID: String
		let name: String
	}

	private func runningApps() -> [RunningApp] {
		let own = Bundle.main.bundleIdentifier
		var seen = Set<String>()
		return NSWorkspace.shared.runningApplications
			.filter { $0.activationPolicy == .regular }
			.compactMap { app -> RunningApp? in
				guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
				return RunningApp(bundleID: id, name: app.localizedName ?? id)
			}
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	private func chooseApp(for category: AppCategory) {
		let panel = NSOpenPanel()
		panel.directoryURL = URL(fileURLWithPath: "/Applications")
		panel.allowedContentTypes = [.applicationBundle]
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
			alert = AppStylesAlert(
				title: String(localized: "Can't add this app"),
				message: String(localized: "\(url.lastPathComponent) has no bundle identifier."))
			return
		}
		add(bundleID, to: category)
	}

	private func add(_ bundleID: String, to category: AppCategory) {
		save { settings in
			// Back to the built-in category means no override is needed.
			let builtIn = AppCategoryResolver.builtInCategory(for: bundleID) ?? .other
			settings.setOverride(bundleID, to: builtIn == category ? nil : category)
		}
	}

	private func displayName(for bundleID: String) -> String {
		if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
			return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
		}
		return AppCategoryCatalog.name(for: bundleID) ?? bundleID
	}

	private func binding(_ keyPath: WritableKeyPath<AppStyleSettings, Bool>) -> Binding<Bool> {
		Binding(get: { model.settings[keyPath: keyPath] }, set: { value in save { $0[keyPath: keyPath] = value } })
	}

	private func styleBinding(_ category: AppCategory) -> Binding<DictationStyle> {
		Binding(get: { model.settings.style(for: category) }, set: { style in save { $0.styles[category] = style } })
	}

	private func save(_ change: (inout AppStyleSettings) -> Void) {
		do {
			try model.update(change)
		} catch {
			AppLogger.shared.recipes.error("Couldn't save app styles: \(error.localizedDescription)")
			alert = AppStylesAlert(
				title: String(localized: "Couldn't save styles"), message: error.localizedDescription)
		}
	}
}

private struct AppStylesAlert: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}
