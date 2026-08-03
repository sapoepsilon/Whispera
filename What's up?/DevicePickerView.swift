import SwiftUI

struct DevicePickerView: View {
	let audioManager: AudioManager
	@State private var deviceManager = AudioDeviceManager.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID

	private let selectedBlue = Color(nsColor: NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0))
	private let unselectedGray = Color(nsColor: NSColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1.0))

	private func isDeviceSelected(_ device: AudioInputDevice) -> Bool {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return device.isDefault
		}
		return device.uid == selectedUID
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				Image(systemName: "mic.fill")
					.font(.system(size: 11))
					.foregroundColor(Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
				Text("Switch Input Device")
					.font(.system(size: 11, weight: .medium, design: .rounded))
					.foregroundColor(Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
			}
			.padding(.bottom, 4)

			Rectangle()
				.fill(Color(nsColor: NSColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1.0)))
				.frame(height: 1)

			Button {
				Task {
					await audioManager.switchInputDevice(to: AudioDeviceManager.systemDefaultUID)
					NotificationCenter.default.post(name: .devicePickerDismissed, object: nil)
				}
			} label: {
				let selected = selectedUID == AudioDeviceManager.systemDefaultUID
				HStack(spacing: 8) {
					Image(systemName: "mic.fill")
						.font(.system(size: 12))
						.frame(width: 20)
						.foregroundColor(selected ? selectedBlue : .secondary)

					Text("System Default")
						.font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded))
						.foregroundColor(selected ? selectedBlue : unselectedGray)
						.lineLimit(1)

					Spacer()

					if selected {
						Image(systemName: "checkmark.circle.fill")
							.font(.system(size: 14))
							.foregroundColor(.blue)
					}
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 5)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(selected ? Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25)) : Color.clear)
				)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			ForEach(deviceManager.availableDevices) { device in
				let selected = isDeviceSelected(device)
				Button {
					Task {
						await audioManager.switchInputDevice(to: device.uid)
						NotificationCenter.default.post(name: .devicePickerDismissed, object: nil)
					}
				} label: {
					HStack(spacing: 8) {
						Image(systemName: device.iconName)
							.font(.system(size: 12))
							.frame(width: 20)
							.foregroundColor(selected ? selectedBlue : .secondary)

						Text(device.name)
							.font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded))
							.foregroundColor(selected ? selectedBlue : unselectedGray)
							.lineLimit(1)

						Spacer()

						if selected {
							Image(systemName: "checkmark.circle.fill")
								.font(.system(size: 14))
								.foregroundColor(.blue)
						}
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 5)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(selected ? Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25)) : Color.clear)
					)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(8)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(Color(nsColor: NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 0.95)))
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.strokeBorder(Color(nsColor: NSColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1.0)), lineWidth: 0.5)
				)
		)
		.shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
		.frame(minWidth: 220)
	}
}

extension Notification.Name {
	static let pillControlsToggled = Notification.Name("PillControlsToggled")
	static let pillControlsDismissed = Notification.Name("PillControlsDismissed")
}

/// String-backed so a page can travel as a notification userInfo hint (WHI-50).
enum PillPage: String { case root, input, action }

/// One wire format for `.pillControlsToggled` payloads, shared by every poster
/// (pill controls button, device icon) and the window that hosts the panel, so
/// an unknown or missing page hint always degrades to the root page.
enum PillControlsRouting {
	static let showKey = "show"
	static let pageKey = "page"

	static func userInfo(show: Bool, page: PillPage? = nil) -> [String: Any] {
		var info: [String: Any] = [showKey: show]
		if let page { info[pageKey] = page.rawValue }
		return info
	}

	static func show(in userInfo: [AnyHashable: Any]?) -> Bool {
		userInfo?[showKey] as? Bool ?? false
	}

	static func page(in userInfo: [AnyHashable: Any]?) -> PillPage {
		(userInfo?[pageKey] as? String).flatMap(PillPage.init(rawValue:)) ?? .root
	}
}

private struct PillPageHeights: PreferenceKey {
	static let defaultValue: [PillPage: CGFloat] = [:]
	static func reduce(value: inout [PillPage: CGFloat], nextValue: () -> [PillPage: CGFloat]) {
		value.merge(nextValue(), uniquingKeysWith: { $1 })
	}
}

/// Fixed geometry of the controls panel. The width never changes, so the panel's
/// target size is fully determined by the measured height of the current page -
/// no per-frame chase needed to size the window that hosts it.
private enum PillControlsMetrics {
	static let width: CGFloat = 250
	static let padding: CGFloat = 8

	// Content reveal as the panel unrolls: each row rises a few points and fades
	// in, lightly staggered. Capped so a long device list still finishes with the
	// frame instead of dealing itself out row by row.
	static let revealRise: CGFloat = 6
	static let revealStagger: Double = 0.035
	static let revealStaggerCap: Double = 0.14

	static func revealDelay(for index: Int) -> Double {
		min(Double(index) * revealStagger, revealStaggerCap)
	}

	static func size(forPageHeight height: CGFloat) -> CGSize {
		CGSize(width: width + padding * 2, height: height + padding * 2)
	}
}

/// Control-Center-style dropdown: a root list (Input Device / Post-dictation
/// Action) that drills into each option list with a back button + slide
/// transitions, then returns to root on select. See WHI-50.
struct PillControlsView: View {
	let audioManager: AudioManager
	/// Reports the panel's *target* size - the size it is animating towards, not
	/// its live per-frame size - so the hosting window animates alongside the
	/// SwiftUI height change on the same curve instead of chasing it. WHI-50.
	var presenter: PillSizePresenter? = nil
	@State private var deviceManager = AudioDeviceManager.shared
	@State private var recipeStore = RecipeStore.shared
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("whisperaDefaultCommandId") private var defaultCommandId = ""
	@State private var page: PillPage
	@State private var heights: [PillPage: CGFloat] = [:]

	init(
		audioManager: AudioManager,
		presenter: PillSizePresenter? = nil,
		initialPage: PillPage = .root
	) {
		self.audioManager = audioManager
		self.presenter = presenter
		_page = State(initialValue: initialPage)
	}

	private let selectedBlue = Color(nsColor: NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0))
	private let unselectedGray = Color(nsColor: NSColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1.0))
	private let mutedGray = Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0))
	private let dividerGray = Color(nsColor: NSColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1.0))
	private let selectedFill = Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25))

	// Grow/shrink + slide between pages. The window that hosts this panel animates
	// its frame on the same constant, so the two stay in lockstep.
	private var pageAnimation: Animation? {
		reduceMotion ? nil : Motion.structural
	}

	private func go(_ destination: PillPage) {
		withAnimation(pageAnimation) { page = destination }
	}

	private func back() {
		withAnimation(pageAnimation) { page = .root }
	}

	// Pages replace in place: the outgoing one fades out and the incoming one's
	// rows stagger in, while the panel height glides. No horizontal travel.
	private var pageTransition: AnyTransition {
		reduceMotion ? .identity : .asymmetric(insertion: .identity, removal: .opacity)
	}

	/// The size the panel is heading for. Every page is measured up-front, so this
	/// is known on the same runloop turn the page changes - which is what lets the
	/// window animate to it instead of following the animation frame by frame.
	/// `nil` until the current page has actually been measured, so the window is
	/// never sized from a placeholder height.
	private var targetSize: CGSize? {
		guard let height = heights[page], height > 1 else { return nil }
		return PillControlsMetrics.size(forPageHeight: height)
	}

	private var currentDevice: AudioInputDevice? {
		if selectedUID == AudioDeviceManager.systemDefaultUID {
			return deviceManager.availableDevices.first(where: \.isDefault)
		}
		return deviceManager.availableDevices.first(where: { $0.uid == selectedUID })
	}

	private var currentActionName: String {
		guard !defaultCommandId.isEmpty,
			let recipe = recipeStore.recipes.first(where: { $0.id == defaultCommandId })
		else { return "No action" }
		return recipe.name.isEmpty ? "Untitled" : recipe.name
	}

	private func isDeviceSelected(_ device: AudioInputDevice) -> Bool {
		if selectedUID == AudioDeviceManager.systemDefaultUID { return device.isDefault }
		return device.uid == selectedUID
	}

	var body: some View {
		// Pinned to the bottom of its window, which sits on the pill's top edge.
		// The panel takes its final layout immediately and the window's animated
		// frame growth is what reveals it, expanding upward out of the pill - the
		// window frame is the clip. Same pattern as the menu bar result glance.
		panel
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
			.onAppear {
				if let targetSize { presenter?.setMeasured(targetSize) }
			}
			.onChange(of: targetSize) { _, newValue in
				guard let newValue else { return }
				presenter?.setMeasured(newValue)
			}
	}

	private var panel: some View {
		ZStack(alignment: .top) {
			pageView(page)
				.id(page)
				.transition(pageTransition)
		}
		.frame(width: PillControlsMetrics.width, height: heights[page], alignment: .top)
		.clipped()
		.background(measurementLayer)
		.onPreferenceChange(PillPageHeights.self) { heights = $0 }
		.padding(PillControlsMetrics.padding)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(Color(nsColor: NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 0.95)))
				.overlay(
					RoundedRectangle(cornerRadius: 12)
						.strokeBorder(Color(nsColor: NSColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1.0)), lineWidth: 0.5)
				)
		)
		.shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
	}

	/// Wraps a row so it rises and fades in behind the panel's growing frame.
	private func revealRow(_ index: Int, @ViewBuilder _ content: () -> some View) -> some View {
		RevealRow(index: index, reduceMotion: reduceMotion, content: content())
	}

	@ViewBuilder private func pageView(_ target: PillPage) -> some View {
		switch target {
		case .root: rootPage
		case .input: inputPage
		case .action: actionPage
		}
	}

	// Hidden copies of every page, measured at the panel width, so each page's
	// target height is known up-front. `.frame(height: heights[page])` then
	// animates straight to it in sync with the slide — the panel grows/shrinks
	// *during* the transition rather than chasing the content after. WHI-50.
	private var measurementLayer: some View {
		ZStack {
			measured(.root)
			measured(.input)
			measured(.action)
		}
		.hidden()
		.allowsHitTesting(false)
	}

	private func measured(_ target: PillPage) -> some View {
		pageView(target)
			.fixedSize(horizontal: false, vertical: true)
			.background(
				GeometryReader { proxy in
					Color.clear.preference(key: PillPageHeights.self, value: [target: proxy.size.height])
				}
			)
	}

	private var rootPage: some View {
		VStack(alignment: .leading, spacing: 4) {
			revealRow(0) { header(icon: "switch.2", title: "Controls", showBack: false) }
			Rectangle().fill(dividerGray).frame(height: 1)
			revealRow(1) {
				moduleRow(
					icon: currentDevice?.iconName ?? "mic.fill",
					title: "Input Device",
					subtitle: currentDevice?.name ?? "System Default"
				) { go(.input) }
			}
			revealRow(2) {
				moduleRow(icon: "list.clipboard", title: "Post-dictation Action", subtitle: currentActionName) { go(.action) }
			}
		}
	}

	private var inputPage: some View {
		VStack(alignment: .leading, spacing: 2) {
			revealRow(0) { header(icon: "mic.fill", title: "Input Device", showBack: true) }
			Rectangle().fill(dividerGray).frame(height: 1)
			revealRow(1) {
				optionRow(icon: "mic.fill", title: "System Default", selected: selectedUID == AudioDeviceManager.systemDefaultUID) {
					back()
					Task { await audioManager.switchInputDevice(to: AudioDeviceManager.systemDefaultUID) }
				}
			}
			ForEach(Array(deviceManager.availableDevices.enumerated()), id: \.element.id) { index, device in
				revealRow(index + 2) {
					optionRow(icon: device.iconName, title: device.name, selected: isDeviceSelected(device)) {
						back()
						Task { await audioManager.switchInputDevice(to: device.uid) }
					}
				}
			}
		}
	}

	private var actionPage: some View {
		VStack(alignment: .leading, spacing: 2) {
			revealRow(0) { header(icon: "list.clipboard", title: "Post-dictation Action", showBack: true) }
			Rectangle().fill(dividerGray).frame(height: 1)
			revealRow(1) {
				noneRow(selected: defaultCommandId.isEmpty) {
					defaultCommandId = ""
					back()
				}
			}
			if !recipeStore.recipes.isEmpty {
				Rectangle().fill(dividerGray.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
			}
			ForEach(Array(recipeStore.recipes.enumerated()), id: \.element.id) { index, recipe in
				revealRow(index + 2) {
					optionRow(icon: "list.clipboard", title: recipe.name.isEmpty ? "Untitled" : recipe.name, selected: defaultCommandId == recipe.id) {
						defaultCommandId = recipe.id
						back()
					}
				}
			}
			Rectangle().fill(dividerGray.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
			revealRow(recipeStore.recipes.count + 2) {
				addYourOwnRow { openCommandSettings() }
			}
		}
	}

	/// Routes to the same AppDelegate settings opener the menu bar uses (native
	/// Settings scene with a retained-window fallback, plus the accessory-app
	/// activation promotion) via a notification rather than an `NSApp.delegate`
	/// cast: with `@NSApplicationDelegateAdaptor`, the installed delegate can be
	/// SwiftUI's own wrapper, and the cast silently failing would make this
	/// button do nothing. The panel dismisses first so it is not left floating
	/// over the window that comes forward.
	private func openCommandSettings() {
		AppLogger.shared.general.info("Pill controls: Add your own tapped, requesting Settings")
		NotificationCenter.default.post(name: .pillControlsDismissed, object: nil)
		NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
	}

	private func addYourOwnRow(tap: @escaping () -> Void) -> some View {
		Button(action: tap) {
			HStack(spacing: 8) {
				Image(systemName: "plus.circle").font(.system(size: 12)).frame(width: 20).foregroundColor(selectedBlue)
				Text("Add your own…").font(.system(size: 13, design: .rounded)).foregroundColor(selectedBlue)
				Spacer()
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Create a post-dictation action in Settings > Recipes")
	}

	private func header(icon: String, title: String, showBack: Bool) -> some View {
		HStack(spacing: 6) {
			if showBack {
				Button { back() } label: {
					Image(systemName: "chevron.left")
						.font(.system(size: 12, weight: .semibold))
						.foregroundColor(selectedBlue)
				}
				.buttonStyle(.plain)
			}
			Image(systemName: icon).font(.system(size: 11)).foregroundColor(mutedGray)
			Text(title).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(mutedGray)
			Spacer()
		}
		.padding(.bottom, 2)
	}

	private func moduleRow(icon: String, title: String, subtitle: String, tap: @escaping () -> Void) -> some View {
		Button(action: tap) {
			HStack(spacing: 10) {
				Image(systemName: icon).font(.system(size: 14)).frame(width: 24).foregroundColor(selectedBlue)
				VStack(alignment: .leading, spacing: 1) {
					Text(title).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(unselectedGray)
					Text(subtitle).font(.system(size: 11, design: .rounded)).foregroundColor(mutedGray).lineLimit(1)
				}
				Spacer()
				Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(mutedGray)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 7)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private func optionRow(icon: String, title: String, selected: Bool, tap: @escaping () -> Void) -> some View {
		Button(action: tap) {
			HStack(spacing: 8) {
				Image(systemName: icon).font(.system(size: 12)).frame(width: 20).foregroundColor(selected ? selectedBlue : .secondary)
				Text(title).font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded)).foregroundColor(selected ? selectedBlue : unselectedGray).lineLimit(1)
				Spacer()
				if selected {
					Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundColor(.blue)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(RoundedRectangle(cornerRadius: 6).fill(selected ? selectedFill : Color.clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private func noneRow(selected: Bool, tap: @escaping () -> Void) -> some View {
		Button(action: tap) {
			HStack(spacing: 8) {
				Image(systemName: "nosign").font(.system(size: 12)).frame(width: 20).foregroundColor(selected ? selectedBlue : mutedGray)
				Text("No action").font(.system(size: 13, weight: selected ? .medium : .regular, design: .rounded)).italic().foregroundColor(selected ? selectedBlue : mutedGray)
				Spacer()
				if selected {
					Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundColor(.blue)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(RoundedRectangle(cornerRadius: 6).fill(selected ? selectedFill : Color.clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

/// A row that reveals itself as it appears. Self-driven rather than keyed off a
/// shared flag: a page flip rebuilds these rows, so the stagger re-runs for the
/// incoming page with no state to reset.
private struct RevealRow<Content: View>: View {
	let index: Int
	let reduceMotion: Bool
	let content: Content
	@State private var shown = false

	var body: some View {
		content
			.opacity(shown ? 1 : 0)
			.offset(y: shown ? 0 : PillControlsMetrics.revealRise)
			.onAppear {
				withAnimation(
					reduceMotion
						? nil
						: Motion.reveal.delay(PillControlsMetrics.revealDelay(for: index))
				) {
					shown = true
				}
			}
	}
}
