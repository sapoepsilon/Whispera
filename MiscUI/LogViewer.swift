import AppKit
import Foundation
import SwiftUI

struct LogEntry: Identifiable, Equatable {
	let id: Int
	let level: LogLevel
	let category: String
	let raw: String

	// Matches LogManager's "[timestamp] [LEVEL] [Category] message" format; anything else
	// (crash reports, multi-line continuations) is kept verbatim at info level.
	static func parse(_ line: String, id: Int) -> LogEntry {
		let fields = bracketedFields(line, count: 3)
		guard fields.count == 3 else {
			return LogEntry(id: id, level: .info, category: "", raw: line)
		}
		let level: LogLevel
		switch fields[1] {
		case "ERROR", "FAULT": level = .error
		case "DEBUG": level = .debug
		default: level = .info
		}
		return LogEntry(id: id, level: level, category: fields[2], raw: line)
	}

	private static func bracketedFields(_ line: String, count: Int) -> [String] {
		var fields: [String] = []
		var rest = Substring(line)
		while fields.count < count {
			rest = rest.drop(while: { $0 == " " })
			guard rest.first == "[", let close = rest.firstIndex(of: "]") else { break }
			fields.append(String(rest[rest.index(after: rest.startIndex)..<close]))
			rest = rest[rest.index(after: close)...]
		}
		return fields
	}

	func matches(minimum: LogLevel, query: String) -> Bool {
		guard level <= minimum else { return false }
		return query.isEmpty || raw.localizedCaseInsensitiveContains(query)
	}
}

@MainActor
@Observable
final class LogTailer {
	private(set) var entries: [LogEntry] = []
	private(set) var fileURL: URL?

	let maxEntries: Int
	let initialReadBytes: UInt64

	private let fileProvider: () -> URL?
	private var offset: UInt64 = 0
	private var partialLine = ""
	private var discardLeadingFragment = false
	private var nextID = 0
	private var timer: Timer?

	init(
		maxEntries: Int = 5000,
		initialReadBytes: UInt64 = 512 * 1024,
		fileProvider: @escaping () -> URL? = { LogManager.shared.currentLogFile }
	) {
		self.maxEntries = maxEntries
		self.initialReadBytes = initialReadBytes
		self.fileProvider = fileProvider
	}

	func start(interval: TimeInterval = 0.5) {
		poll()
		guard timer == nil else { return }
		timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			Task { @MainActor in
				self?.poll()
			}
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	func clearView() {
		entries.removeAll()
	}

	func poll() {
		let url = fileProvider()
		if url != fileURL {
			fileURL = url
			offset = 0
			partialLine = ""
			discardLeadingFragment = false
			entries.removeAll()
		}
		guard let url,
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let size = (attributes[.size] as? NSNumber)?.uint64Value
		else { return }

		if size < offset {
			offset = 0
			partialLine = ""
			discardLeadingFragment = false
			entries.removeAll()
		}
		if offset == 0 && size > initialReadBytes {
			offset = size - initialReadBytes
			discardLeadingFragment = true
		}
		guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
		defer { try? handle.close() }

		do {
			try handle.seek(toOffset: offset)
			guard let data = try handle.read(upToCount: Int(size - offset)), !data.isEmpty else {
				return
			}
			offset += UInt64(data.count)
			append(String(decoding: data, as: UTF8.self))
		} catch {
			AppLogger.shared.general.error("Log viewer failed to read \(url.lastPathComponent): \(error)")
		}
	}

	private func append(_ chunk: String) {
		let text = partialLine + chunk
		var lines = text.components(separatedBy: "\n")
		partialLine = lines.removeLast()
		if discardLeadingFragment, !lines.isEmpty {
			lines.removeFirst()
			discardLeadingFragment = false
		}
		let newEntries = lines.filter { !$0.isEmpty }.map { line -> LogEntry in
			defer { nextID += 1 }
			return LogEntry.parse(line, id: nextID)
		}
		guard !newEntries.isEmpty else { return }
		entries.append(contentsOf: newEntries)
		if entries.count > maxEntries {
			entries.removeFirst(entries.count - maxEntries)
		}
	}
}

struct LogLevelSettingRow: View {
	@State private var level = LogLevel.stored()

	var body: some View {
		SettingRow("Log Level", description: "How much detail is written to the log file") {
			Picker("", selection: $level) {
				ForEach(LogLevel.allCases) { level in
					Text(level.displayName).tag(level)
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)
			.frame(width: 160)
			.onChange(of: level) { _, newValue in
				LogLevel.store(newValue)
			}
		}
	}
}

struct LogViewerView: View {
	@State private var tailer = LogTailer()
	@State private var filterLevel: LogLevel = .debug
	@State private var query = ""
	@State private var autoScroll = true
	@State private var isPaused = false

	private var visibleEntries: [LogEntry] {
		tailer.entries.filter { $0.matches(minimum: filterLevel, query: query) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			SettingsSection("Logging") {
				LogLevelSettingRow()
				Text("Press ⇧⌘D in Settings to hide this tab.")
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Divider()

			HStack(spacing: 8) {
				Picker("Show", selection: $filterLevel) {
					ForEach(LogLevel.allCases.reversed()) { level in
						Text(level.displayName).tag(level)
					}
				}
				.pickerStyle(.menu)
				.frame(width: 170)

				TextField("Filter", text: $query)
					.textFieldStyle(.roundedBorder)

				Toggle("Auto-scroll", isOn: $autoScroll)
					.toggleStyle(.checkbox)
			}

			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 1) {
						ForEach(visibleEntries) { entry in
							Text(entry.raw)
								.font(.system(size: 11, design: .monospaced))
								.foregroundColor(color(for: entry.level))
								.textSelection(.enabled)
								.frame(maxWidth: .infinity, alignment: .leading)
								.id(entry.id)
						}
					}
					.padding(8)
				}
				.background(Color(NSColor.textBackgroundColor))
				.clipShape(RoundedRectangle(cornerRadius: 6))
				.frame(minHeight: 280)
				.onChange(of: tailer.entries.last?.id) { _, lastID in
					guard autoScroll, let lastID = visibleEntries.last?.id ?? lastID else { return }
					proxy.scrollTo(lastID, anchor: .bottom)
				}
			}

			HStack(spacing: 8) {
				Text(tailer.fileURL?.lastPathComponent ?? String(localized: "No log file yet"))
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer()
				Button(isPaused ? "Resume" : "Pause") {
					isPaused.toggle()
					if isPaused { tailer.stop() } else { tailer.start() }
				}
				Button("Copy") {
					let text = visibleEntries.map(\.raw).joined(separator: "\n")
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}
				Button("Clear View") {
					tailer.clearView()
				}
				Button("Show in Finder") {
					if let url = tailer.fileURL {
						NSWorkspace.shared.activateFileViewerSelecting([url])
					}
				}
				.disabled(tailer.fileURL == nil)
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
		}
		.padding(20)
		.onAppear { tailer.start() }
		.onDisappear { tailer.stop() }
	}

	private func color(for level: LogLevel) -> Color {
		switch level {
		case .error: return .red
		case .info: return .primary
		case .debug: return .secondary
		}
	}
}

struct DebugModeShortcut: View {
	@AppStorage(DebugMode.defaultsKey) private var debugModeEnabled = false

	var body: some View {
		Button("Toggle Debug Mode") {
			DebugMode.toggle()
		}
		.keyboardShortcut("d", modifiers: [.command, .shift])
		.frame(width: 0, height: 0)
		.opacity(0)
		.accessibilityHidden(true)
	}
}
