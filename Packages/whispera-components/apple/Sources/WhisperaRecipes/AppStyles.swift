import Foundation

/// Which kind of app a dictation lands in. The style the user picked for the
/// category decides how Clean up formats the text (caps and punctuation only).
public enum AppCategory: String, Codable, CaseIterable, Sendable {
	case personal, work, email, code, other

	/// How the category is named inside a style fragment.
	public var promptLabel: String {
		switch self {
		case .personal: return "a personal chat message"
		case .work: return "a work chat message"
		case .email: return "an email"
		case .code: return "a developer tool (editor, terminal or coding agent)"
		case .other: return "general writing"
		}
	}
}

public enum DictationStyle: String, Codable, CaseIterable, Sendable {
	/// `verbatim` adds no fragment: the recipe runs as written.
	case formal, casual, veryCasual, excited, verbatim

	public static func allowed(in category: AppCategory) -> [DictationStyle] {
		switch category {
		case .personal: return [.formal, .casual, .veryCasual]
		case .work, .email, .other: return [.formal, .casual, .excited]
		case .code: return [.verbatim, .casual]
		}
	}
}

/// "Match style to app": one style per category plus the user's own app → category moves.
public struct AppStyleSettings: Codable, Equatable, Sendable {
	public static let currentVersion = 1

	public var enabled: Bool
	public var styles: [AppCategory: DictationStyle]
	/// Lowercased bundle id → category. Beats the built-in catalog.
	public var overrides: [String: AppCategory]
	public var version: Int

	public init(
		enabled: Bool = false, styles: [AppCategory: DictationStyle] = AppStyleSettings.defaultStyles,
		overrides: [String: AppCategory] = [:], version: Int = AppStyleSettings.currentVersion
	) {
		self.enabled = enabled
		self.styles = styles
		self.overrides = overrides
		self.version = version
	}

	public static let defaultStyles: [AppCategory: DictationStyle] = [
		.personal: .casual, .work: .casual, .email: .formal, .code: .verbatim, .other: .formal,
	]

	public static let defaults = AppStyleSettings()

	/// The stored style when it is allowed for the category; otherwise the category's first allowed style.
	public func style(for category: AppCategory) -> DictationStyle {
		let allowed = DictationStyle.allowed(in: category)
		if let stored = styles[category], allowed.contains(stored) { return stored }
		return allowed[0]
	}

	public mutating func setOverride(_ bundleID: String, to category: AppCategory?) {
		let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !key.isEmpty else { return }
		overrides[key] = category
	}

	private enum CodingKeys: String, CodingKey { case enabled, styles, overrides, version }

	/// Lenient: unknown categories or styles are dropped, a style a category does not allow falls
	/// back to that category's first allowed style, and anything missing takes its default.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
		version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
		var styles = Self.defaultStyles
		for (key, value) in try container.decodeIfPresent([String: String].self, forKey: .styles) ?? [:] {
			guard let category = AppCategory(rawValue: key) else { continue }
			let allowed = DictationStyle.allowed(in: category)
			if let style = DictationStyle(rawValue: value), allowed.contains(style) {
				styles[category] = style
			} else {
				styles[category] = allowed[0]
			}
		}
		self.styles = styles
		var overrides: [String: AppCategory] = [:]
		for (key, value) in try container.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:] {
			let id = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard !id.isEmpty, let category = AppCategory(rawValue: value) else { continue }
			overrides[id] = category
		}
		self.overrides = overrides
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(enabled, forKey: .enabled)
		try container.encode(Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .styles)
		try container.encode(Dictionary(uniqueKeysWithValues: overrides.map { ($0.key, $0.value.rawValue) }), forKey: .overrides)
		try container.encode(version, forKey: .version)
	}
}

/// The app a dictation was started in.
public struct DictationAppContext: Codable, Equatable, Sendable {
	public enum Platform: String, Codable, Sendable { case mac, ios }

	/// nil when detection failed or the dictation started in Whispera itself.
	public var bundleID: String?
	public var appName: String?
	public var platform: Platform

	public init(bundleID: String?, appName: String? = nil, platform: Platform) {
		let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
		self.bundleID = trimmed?.isEmpty == false ? trimmed : nil
		self.appName = appName
		self.platform = platform
	}
}

public enum AppCategoryResolver {
	/// overrides (exact, case-insensitive) → built-in exact → built-in prefix → `.other`.
	public static func category(for bundleID: String?, settings: AppStyleSettings) -> AppCategory {
		guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else {
			return .other
		}
		if let category = settings.overrides[id] { return category }
		return builtInCategory(for: id) ?? .other
	}

	/// The catalog's answer alone, ignoring the user's overrides.
	public static func builtInCategory(for bundleID: String) -> AppCategory? {
		let id = bundleID.lowercased()
		if let category = AppCategoryCatalog.exact[id] { return category }
		return AppCategoryCatalog.prefixes.first { id.hasPrefix($0.0) }?.1
	}
}

/// Built-in app → category lists. Mac and iOS ids of one service sit next to each other.
public enum AppCategoryCatalog {
	public struct Entry: Equatable, Sendable {
		public let bundleID: String
		public let name: String
		public let category: AppCategory
		public let platform: DictationAppContext.Platform
	}

	private static func mac(_ id: String, _ name: String, _ c: AppCategory) -> Entry {
		Entry(bundleID: id, name: name, category: c, platform: .mac)
	}
	private static func ios(_ id: String, _ name: String, _ c: AppCategory) -> Entry {
		Entry(bundleID: id, name: name, category: c, platform: .ios)
	}

	/// Ids that are the same on both platforms are listed once, as Mac entries.
	public static let entries: [Entry] = [
		// personal
		mac("com.apple.MobileSMS", "Messages", .personal),
		mac("net.whatsapp.WhatsApp", "WhatsApp", .personal),
		mac("ru.keepcoder.Telegram", "Telegram", .personal),
		mac("com.tdesktop.Telegram", "Telegram Desktop", .personal),
		ios("ph.telegra.Telegraph", "Telegram", .personal),
		mac("org.whispersystems.signal-desktop", "Signal", .personal),
		ios("org.whispersystems.signal", "Signal", .personal),
		mac("com.hnc.Discord", "Discord", .personal),
		mac("com.discordapp.Discord", "Discord", .personal),
		ios("com.hammerandchisel.discord", "Discord", .personal),
		mac("com.facebook.archon", "Messenger", .personal),
		ios("com.facebook.Messenger", "Messenger", .personal),
		ios("com.burbn.instagram", "Instagram", .personal),
		mac("im.beeper", "Beeper", .personal),
		mac("com.kishanbagaria.jack", "Texts", .personal),
		mac("com.tencent.xinWeChat", "WeChat", .personal),
		ios("com.tencent.xin", "WeChat", .personal),
		mac("jp.naver.line.mac", "LINE", .personal),
		ios("jp.naver.line", "LINE", .personal),
		// work
		mac("com.tinyspeck.slackmacgap", "Slack", .work),
		mac("com.slack.Slack", "Slack", .work),
		ios("com.tinyspeck.chatlyio", "Slack", .work),
		mac("com.microsoft.teams", "Microsoft Teams", .work),
		mac("com.microsoft.teams2", "Microsoft Teams", .work),
		ios("com.microsoft.skype.teams", "Microsoft Teams", .work),
		mac("us.zoom.xos", "Zoom", .work),
		ios("us.zoom.videomeetings", "Zoom", .work),
		mac("Mattermost.Desktop", "Mattermost", .work),
		mac("com.electron.lark", "Lark", .work),
		mac("com.google.Chrome.app.mdpkiolbdkhdjpekfbkbmhigcaggjagi", "Google Chat", .work),
		ios("com.google.Dynamite", "Google Chat", .work),
		ios("com.linkedin.LinkedIn", "LinkedIn", .work),
		// email
		mac("com.apple.mail", "Mail", .email),
		ios("com.apple.mobilemail", "Mail", .email),
		mac("com.microsoft.Outlook", "Outlook", .email),
		ios("com.microsoft.Office.Outlook", "Outlook", .email),
		mac("com.google.Gmail", "Gmail", .email),
		mac("com.superhuman.electron", "Superhuman", .email),
		ios("com.superhuman.Superhuman", "Superhuman", .email),
		mac("com.mimestream.Mimestream", "Mimestream", .email),
		mac("org.mozilla.thunderbird", "Thunderbird", .email),
		mac("it.bloop.airmail2", "Airmail", .email),
		mac("com.postbox-inc.postbox", "Postbox", .email),
		mac("com.emclient.mail.client", "eM Client", .email),
		mac("com.readdle.SparkDesktop", "Spark", .email),
		mac("com.readdle.smartemail-Mac", "Spark", .email),
		ios("com.readdle.smartemail", "Spark", .email),
		mac("com.mailspring.mailspring", "Mailspring", .email),
		mac("com.edisonmail.edisonmail", "Edison Mail", .email),
		mac("com.frontapp.Front", "Front", .email),
		mac("com.hey.app.desktop", "HEY", .email),
		ios("com.hey.app.ios", "HEY", .email),
		mac("io.canarymail.mac", "Canary Mail", .email),
		mac("com.missiveapp.osx", "Missive", .email),
		mac("com.freron.MailMate", "MailMate", .email),
		ios("ch.protonmail.protonmail", "Proton Mail", .email),
		// code
		mac("com.microsoft.VSCode", "VS Code", .code),
		mac("com.microsoft.VSCodeInsiders", "VS Code Insiders", .code),
		mac("com.todesktop.230313mzl4w4u92", "Cursor", .code),
		mac("com.exafunction.windsurf", "Windsurf", .code),
		mac("com.apple.dt.Xcode", "Xcode", .code),
		mac("dev.zed.Zed", "Zed", .code),
		mac("com.sublimetext.4", "Sublime Text", .code),
		mac("com.sublimetext.3", "Sublime Text 3", .code),
		mac("com.barebones.bbedit", "BBEdit", .code),
		mac("com.apple.Terminal", "Terminal", .code),
		mac("com.googlecode.iterm2", "iTerm2", .code),
		mac("dev.warp.Warp-Stable", "Warp", .code),
		mac("com.mitchellh.ghostty", "Ghostty", .code),
		mac("net.kovidgoyal.kitty", "kitty", .code),
		mac("io.alacritty", "Alacritty", .code),
		mac("co.zeit.hyper", "Hyper", .code),
		mac("com.openai.codex", "Codex", .code),
		mac("com.anthropic.claudefordesktop", "Claude", .code),
		ios("com.appliedphasor.working-copy", "Working Copy", .code),
		ios("com.carloscabanero.BlinkShell", "Blink Shell", .code),
		ios("com.crystalnix.ServerAuditor", "Termius", .code),
		ios("com.openai.codex.ios", "Codex", .code),
	]

	/// Lowercased bundle id → category.
	public static let exact: [String: AppCategory] = Dictionary(
		entries.map { ($0.bundleID.lowercased(), $0.category) }, uniquingKeysWith: { first, _ in first })

	/// Lowercased prefixes, checked in order after an exact miss.
	public static let prefixes: [(String, AppCategory)] = [
		("com.jetbrains.", .code),
		("com.google.android.studio", .code),
	]

	public static func entries(in category: AppCategory, platform: DictationAppContext.Platform) -> [Entry] {
		entries.filter { $0.category == category && $0.platform == platform }
	}

	public static func name(for bundleID: String) -> String? {
		let id = bundleID.lowercased()
		return entries.first { $0.bundleID.lowercased() == id }?.name
	}
}

/// The prompt text that turns a style into formatting rules. Constants, not user-editable.
public enum StyleFragment {
	public static func text(_ style: DictationStyle, category: AppCategory) -> String? {
		let rule: String
		switch style {
		case .verbatim: return nil
		case .formal:
			rule = "Capitalize the first word of every sentence and proper nouns. End every sentence with a period, question mark or exclamation mark. Use commas where grammar needs them."
		case .casual:
			rule = "Capitalize the first word of every sentence and proper nouns. Use light punctuation: keep commas only where they aid reading and drop the final period of the message. Keep question marks."
		case .veryCasual:
			rule = "Write everything in lowercase except \"I\" and acronyms people normally write in capitals. Use light punctuation and drop the final period. Keep question marks."
		case .excited:
			rule = "Capitalize normally. End statements that express enthusiasm, thanks or agreement with an exclamation mark instead of a period. Use at most one exclamation mark in a row."
		}
		var parts = [
			"Format the cleaned text for \(category.promptLabel). Only change capitalization, punctuation, spacing and line breaks as described below. Never change, add or remove words because of this formatting rule.",
			rule,
		]
		if category == .email { parts.append(emailAddOn) }
		if category == .code, style == .casual { parts.append(codeAddOn) }
		return parts.joined(separator: "\n")
	}

	public static let emailAddOn =
		"If the text begins with a greeting (Hi/Hey/Hello/Dear + name), put the greeting on its own line followed by a blank line. If it ends with a sign-off (Best, Thanks, Cheers, Regards + name), put the sign-off and the name on their own lines after a blank line."

	public static let codeAddOn =
		"Leave anything that looks like code untouched: identifiers, file names, paths, flags, commands and version numbers keep their exact spelling and case. Do not add a final period. Do not wrap the text in quotes or code fences."

	/// Static example of each style on the lunch sentence, for settings screens.
	public static func example(_ style: DictationStyle) -> String {
		switch style {
		case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12."
		case .casual: return "Hey are you free for lunch tomorrow? Let's do 12"
		case .veryCasual: return "hey are you free for lunch tomorrow? let's do 12"
		case .excited: return "Hey, are you free for lunch tomorrow? Let's do 12!"
		case .verbatim: return "hey are you free for lunch tomorrow lets do 12"
		}
	}
}

/// What styling decided for one run, for logs and history.
public struct AppStyleApplication: Equatable, Sendable {
	public let category: AppCategory
	public let style: DictationStyle
	/// False for `verbatim`: the recipe ran unchanged.
	public let fragmentAdded: Bool

	public init(category: AppCategory, style: DictationStyle, fragmentAdded: Bool) {
		self.category = category
		self.style = style
		self.fragmentAdded = fragmentAdded
	}
}

public enum AppStyleComposer {
	/// The built-in Clean up recipe's fixed id (same on the Mac app and its link helper).
	public static let cleanUpRecipeID = "whispera.builtin.cleanup"

	public static func qualifies(_ recipe: Recipe) -> Bool {
		recipe.id == cleanUpRecipeID || recipe.applyAppStyle
	}

	/// The recipe to run and what was applied, or nil when styling does not apply (styles off and
	/// no override, or a recipe that has not opted in). The fragment is joined after any existing
	/// system prompt of the last llm step, since that step produces the pasted text.
	public static func apply(
		to recipe: Recipe, settings: AppStyleSettings, context: DictationAppContext?,
		styleOverride: DictationStyle? = nil
	) -> (recipe: Recipe, application: AppStyleApplication)? {
		guard qualifies(recipe), settings.enabled || styleOverride != nil,
			let index = recipe.steps.lastIndex(where: { $0.type == "llm" })
		else { return nil }
		let category = AppCategoryResolver.category(for: context?.bundleID, settings: settings)
		let style = styleOverride ?? settings.style(for: category)
		guard let fragment = StyleFragment.text(style, category: category) else {
			return (recipe, AppStyleApplication(category: category, style: style, fragmentAdded: false))
		}
		var styled = recipe
		let existing = styled.steps[index].config.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		styled.steps[index].config.systemPrompt = existing.isEmpty ? fragment : existing + "\n\n" + fragment
		return (styled, AppStyleApplication(category: category, style: style, fragmentAdded: true))
	}
}

/// `app-styles.json`, next to `recipes.json`. Read by the Mac app and its link helper.
public struct AppStyleSettingsStore: Sendable {
	public let fileURL: URL

	public init(fileURL: URL? = nil) {
		self.fileURL = fileURL ?? Self.defaultFileURL()
	}

	public static func defaultFileURL() -> URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Whispera", isDirectory: true)
			.appendingPathComponent("app-styles.json")
	}

	/// Missing or undecodable file → defaults. An undecodable file is left alone: it is more
	/// likely written by a newer build than garbage.
	public func load() -> AppStyleSettings {
		guard let data = try? Data(contentsOf: fileURL), data.count <= 512 * 1024,
			let settings = try? JSONDecoder().decode(AppStyleSettings.self, from: data)
		else { return .defaults }
		return Self.migrate(settings)
	}

	public func save(_ settings: AppStyleSettings) throws {
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(Self.migrate(settings)).write(to: fileURL, options: .atomic)
	}

	/// Version hook: older files are brought up to the current version here.
	public static func migrate(_ settings: AppStyleSettings) -> AppStyleSettings {
		var settings = settings
		if settings.version < AppStyleSettings.currentVersion { settings.version = AppStyleSettings.currentVersion }
		return settings
	}
}
