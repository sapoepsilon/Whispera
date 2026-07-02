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

private enum PillPage { case root, input, action }

private struct PillPageHeights: PreferenceKey {
	static let defaultValue: [PillPage: CGFloat] = [:]
	static func reduce(value: inout [PillPage: CGFloat], nextValue: () -> [PillPage: CGFloat]) {
		value.merge(nextValue(), uniquingKeysWith: { $1 })
	}
}

/// Control-Center-style dropdown: a root list (Input Device / Post-dictation
/// Action) that drills into each option list with a back button + slide
/// transitions, then returns to root on select. See WHI-50.
struct PillControlsView: View {
	let audioManager: AudioManager
	/// Reports the panel's *live* (animating) size so the hosting window can
	/// follow it smoothly instead of snapping to the ideal size. WHI-50.
	var onSize: ((CGSize) -> Void)? = nil
	@State private var deviceManager = AudioDeviceManager.shared
	@State private var recipeStore = RecipeStore.shared
	@AppStorage("selectedAudioInputDeviceUID") private var selectedUID = AudioDeviceManager.systemDefaultUID
	@AppStorage("whisperaDefaultCommandId") private var defaultCommandId = ""
	@State private var page: PillPage = .root
	@State private var forward = true
	@State private var heights: [PillPage: CGFloat] = [:]

	private let selectedBlue = Color(nsColor: NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0))
	private let unselectedGray = Color(nsColor: NSColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1.0))
	private let mutedGray = Color(nsColor: NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0))
	private let dividerGray = Color(nsColor: NSColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1.0))
	private let selectedFill = Color(nsColor: NSColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.25))

	// Grow/shrink + slide between pages. Tune here: lower `response` = faster,
	// higher = slower; lower `dampingFraction` = more bounce.
	private let pageAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.78)

	private func go(_ destination: PillPage) {
		forward = true
		withAnimation(pageAnimation) { page = destination }
	}

	private func back() {
		forward = false
		withAnimation(pageAnimation) { page = .root }
	}

	private var pageTransition: AnyTransition {
		.asymmetric(
			insertion: .move(edge: forward ? .trailing : .leading),
			removal: .move(edge: forward ? .leading : .trailing)
		)
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
		ZStack(alignment: .top) {
			pageView(page)
				.id(page)
				.transition(pageTransition)
		}
		.frame(width: 250, height: heights[page], alignment: .top)
		.clipped()
		.background(measurementLayer)
		.onPreferenceChange(PillPageHeights.self) { heights = $0 }
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
		.background(
			GeometryReader { proxy in
				Color.clear
					.onAppear { onSize?(proxy.size) }
					.onChange(of: proxy.size) { onSize?($1) }
			}
		)
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
			header(icon: "switch.2", title: "Controls", showBack: false)
			Rectangle().fill(dividerGray).frame(height: 1)
			moduleRow(
				icon: currentDevice?.iconName ?? "mic.fill",
				title: "Input Device",
				subtitle: currentDevice?.name ?? "System Default"
			) { go(.input) }
			moduleRow(icon: "list.clipboard", title: "Post-dictation Action", subtitle: currentActionName) { go(.action) }
		}
	}

	private var inputPage: some View {
		VStack(alignment: .leading, spacing: 2) {
			header(icon: "mic.fill", title: "Input Device", showBack: true)
			Rectangle().fill(dividerGray).frame(height: 1)
			optionRow(icon: "mic.fill", title: "System Default", selected: selectedUID == AudioDeviceManager.systemDefaultUID) {
				back()
				Task { await audioManager.switchInputDevice(to: AudioDeviceManager.systemDefaultUID) }
			}
			ForEach(deviceManager.availableDevices) { device in
				optionRow(icon: device.iconName, title: device.name, selected: isDeviceSelected(device)) {
					back()
					Task { await audioManager.switchInputDevice(to: device.uid) }
				}
			}
		}
	}

	private var actionPage: some View {
		VStack(alignment: .leading, spacing: 2) {
			header(icon: "list.clipboard", title: "Post-dictation Action", showBack: true)
			Rectangle().fill(dividerGray).frame(height: 1)
			noneRow(selected: defaultCommandId.isEmpty) {
				defaultCommandId = ""
				back()
			}
			if !recipeStore.recipes.isEmpty {
				Rectangle().fill(dividerGray.opacity(0.5)).frame(height: 1).padding(.vertical, 2)
			}
			ForEach(recipeStore.recipes) { recipe in
				optionRow(icon: "list.clipboard", title: recipe.name.isEmpty ? "Untitled" : recipe.name, selected: defaultCommandId == recipe.id) {
					defaultCommandId = recipe.id
					back()
				}
			}
		}
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
