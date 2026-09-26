import Foundation

/// Describes a model download or load that is still running while dictation is available.
/// Dictation never waits for the new model when another engine is already loaded: it keeps
/// transcribing with that engine, and this notice is how the UI says so.
struct ModelSwitchNotice: Equatable {
	enum Phase: Equatable {
		case downloading
		case loading
	}

	let phase: Phase
	let pendingModel: String
	/// The model that transcribes until the pending one is ready; nil means dictation waits.
	let activeModel: String?

	static func make(
		activeModel: String?,
		hasLoadedEngine: Bool,
		loadingModel: String?,
		downloadingModel: String?
	) -> ModelSwitchNotice? {
		let active = hasLoadedEngine ? activeModel : nil
		let phase: Phase
		let pending: String
		if let loadingModel {
			phase = .loading
			pending = loadingModel
		} else if let downloadingModel {
			phase = .downloading
			pending = downloadingModel
		} else {
			return nil
		}
		guard pending != active else { return nil }
		return ModelSwitchNotice(phase: phase, pendingModel: pending, activeModel: active)
	}

	func title(name: (String) -> String) -> String {
		let pendingName = name(pendingModel)
		switch phase {
		case .downloading: return String(localized: "Downloading \(pendingName)...")
		case .loading: return String(localized: "Loading \(pendingName)...")
		}
	}

	func detail(name: (String) -> String) -> String {
		guard let activeModel else { return String(localized: "Dictation waits until it is ready") }
		return String(localized: "Dictation uses \(name(activeModel)) until it is ready")
	}

	/// Compact wording for the recording pill, or nil when there is no other model to name.
	func pillText(name: (String) -> String) -> String? {
		guard let activeModel else { return nil }
		return String(localized: "Using \(name(activeModel)) · \(name(pendingModel)) loading")
	}

	/// "Small (Multilingual) - 244MB" -> "Small (Multilingual)"
	static func mediumName(_ displayName: String) -> String {
		guard let range = displayName.range(of: " - ", options: .backwards) else { return displayName }
		return String(displayName[..<range.lowerBound])
	}

	/// "Parakeet TDT v3 (25 languages, auto-detect) - 460MB" -> "Parakeet TDT v3"
	static func shortName(_ displayName: String) -> String {
		let medium = mediumName(displayName)
		guard medium.hasSuffix(")"), let open = medium.range(of: " (", options: .backwards) else {
			return medium
		}
		return String(medium[..<open.lowerBound])
	}
}

extension WhisperKitTranscriber {
	var modelSwitchNotice: ModelSwitchNotice? {
		ModelSwitchNotice.make(
			activeModel: currentModel,
			hasLoadedEngine: hasLoadedEngine,
			loadingModel: loadingModelName,
			downloadingModel: isDownloadingModel ? downloadingModelName : nil
		)
	}

	static func mediumModelName(for model: String) -> String {
		ModelSwitchNotice.mediumName(getModelDisplayName(for: model))
	}

	static func shortModelName(for model: String) -> String {
		ModelSwitchNotice.shortName(getModelDisplayName(for: model))
	}
}
