import Foundation
import WhisperKit

struct CustomWhisperModel: Codable, Identifiable, Equatable, Sendable {
	enum Source: Codable, Equatable, Sendable {
		case huggingFace(repo: String, variant: String)
		case localFolder(originalPath: String)
	}

	static let idPrefix = "custom:"

	let id: String
	var displayName: String
	let source: Source
	let folderPath: String
	let addedAt: Date

	var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

	var sourceDescription: String {
		switch source {
		case .huggingFace(let repo, let variant): return "\(repo) / \(variant)"
		case .localFolder(let originalPath): return String(localized: "Imported from \(originalPath)")
		}
	}

	static func isCustomID(_ id: String) -> Bool {
		id.hasPrefix(idPrefix)
	}

	/// The tokenizer is looked up in the model folder first, then fetched into downloadBase when absent.
	func whisperKitConfig(downloadBase: URL?, computeOptions: ModelComputeOptions) -> WhisperKitConfig {
		WhisperKitConfig(
			downloadBase: downloadBase,
			modelFolder: folderPath,
			computeOptions: computeOptions,
			prewarm: true,
			load: true,
			download: false
		)
	}
}

struct HuggingFaceModelReference: Equatable, Sendable {
	static let builtInRepository = "argmaxinc/whisperkit-coreml"

	let repo: String
	let variant: String

	var isBuiltInRepository: Bool { repo.lowercased() == Self.builtInRepository }

	/// Accepts `owner/repo` or a huggingface.co URL; a `/tree/<revision>/<variant>` URL supplies the variant itself.
	static func parse(repoInput: String, variant variantInput: String?) -> HuggingFaceModelReference? {
		var input = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
		for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"]
		where input.lowercased().hasPrefix(prefix) {
			input = String(input.dropFirst(prefix.count))
			break
		}
		let parts = input.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
		guard parts.count >= 2 else { return nil }

		let repo = "\(parts[0])/\(parts[1])"
		var variant = variantInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if variant.isEmpty, parts.count >= 5, parts[2] == "tree" {
			variant = parts[4]
		} else if parts.count > 2, parts[2] != "tree" {
			return nil
		}

		guard isValidSegment(parts[0]), isValidSegment(parts[1]), isValidSegment(variant) else {
			return nil
		}
		return HuggingFaceModelReference(repo: repo, variant: variant)
	}

	private static func isValidSegment(_ value: String) -> Bool {
		let allowed = CharacterSet(
			charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
		guard let first = value.unicodeScalars.first, first != ".", first != "-", first != "_" else {
			return false
		}
		return value.unicodeScalars.allSatisfy { allowed.contains($0) }
	}
}

enum CustomModelError: LocalizedError, Equatable {
	case invalidReference
	case notADirectory(String)
	case missingComponents([String])
	case alreadyAdded(String)
	case inUse(String)
	case notFound(String)
	case builtInRepository

	var errorDescription: String? {
		switch self {
		case .invalidReference:
			return
				"Enter a Hugging Face repo as owner/repo plus the model folder name, or paste a huggingface.co/owner/repo/tree/main/<folder> link."
		case .notADirectory(let path):
			return "\(path) is not a folder."
		case .missingComponents(let names):
			return
				"This isn't a WhisperKit CoreML model. Missing: \(names.joined(separator: ", ")) (.mlmodelc or .mlpackage)."
		case .alreadyAdded(let name):
			return "\(name) has already been added."
		case .inUse(let name):
			return "\(name) is the loaded model. Switch to another model before removing it."
		case .notFound(let id):
			return "Custom model \(id) was not found."
		case .builtInRepository:
			return "Models from argmaxinc/whisperkit-coreml are already in the model list above."
		}
	}
}

enum CustomModelValidator {
	static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

	static func missingComponents(in folder: URL, fileManager: FileManager = .default) -> [String] {
		requiredComponents.filter { name in
			!["mlmodelc", "mlpackage"].contains { ext in
				fileManager.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
			}
		}
	}

	static func validate(folder: URL, fileManager: FileManager = .default) throws {
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
		else {
			throw CustomModelError.notADirectory(folder.path)
		}
		let missing = missingComponents(in: folder, fileManager: fileManager)
		guard missing.isEmpty else { throw CustomModelError.missingComponents(missing) }
	}
}

@MainActor
@Observable
final class CustomModelStore {
	static let storageKey = "customWhisperModels"

	static let shared: CustomModelStore = {
		let appSupport =
			FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSTemporaryDirectory())
		return CustomModelStore(
			defaults: .standard,
			importRoot: appSupport.appendingPathComponent("Whispera/models/custom", isDirectory: true),
			ownedRoots: [appSupport.appendingPathComponent("Whispera/models", isDirectory: true)]
		)
	}()

	private(set) var models: [CustomWhisperModel] = []
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored let importRoot: URL
	@ObservationIgnored private let ownedRoots: [URL]

	init(defaults: UserDefaults, importRoot: URL, ownedRoots: [URL]) {
		self.defaults = defaults
		self.importRoot = importRoot
		self.ownedRoots = ownedRoots + [importRoot]
		load()
	}

	var availableModels: [CustomWhisperModel] {
		models.filter { FileManager.default.fileExists(atPath: $0.folderPath) }
	}

	func model(id: String) -> CustomWhisperModel? {
		models.first { $0.id == id }
	}

	func isAvailable(id: String) -> Bool {
		guard let model = model(id: id) else { return false }
		return FileManager.default.fileExists(atPath: model.folderPath)
	}

	static func slug(for name: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
		let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		let collapsed = String(mapped)
			.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
			.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
		return collapsed.isEmpty ? "model" : collapsed.lowercased()
	}

	func uniqueSlug(for name: String) -> String {
		let base = Self.slug(for: name)
		var candidate = base
		var counter = 2
		while model(id: CustomWhisperModel.idPrefix + candidate) != nil
			|| FileManager.default.fileExists(atPath: importRoot.appendingPathComponent(candidate).path)
		{
			candidate = "\(base)-\(counter)"
			counter += 1
		}
		return candidate
	}

	func containsHuggingFace(_ reference: HuggingFaceModelReference) -> Bool {
		models.contains { $0.source == .huggingFace(repo: reference.repo, variant: reference.variant) }
	}

	/// Copies the folder into Whispera's own storage so the model survives the original being moved or deleted.
	func importLocalFolder(_ folder: URL, displayName: String? = nil) async throws -> CustomWhisperModel {
		try CustomModelValidator.validate(folder: folder)
		let name = displayName ?? folder.lastPathComponent
		let slug = uniqueSlug(for: name)
		let destination = importRoot.appendingPathComponent(slug, isDirectory: true)
		let root = importRoot

		try await Task.detached(priority: .userInitiated) {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try FileManager.default.copyItem(at: folder, to: destination)
		}.value

		let model = CustomWhisperModel(
			id: CustomWhisperModel.idPrefix + slug,
			displayName: name,
			source: .localFolder(originalPath: folder.path),
			folderPath: destination.path,
			addedAt: Date()
		)
		models.append(model)
		save()
		AppLogger.shared.transcriber.log("Imported custom model \(model.id) from \(folder.path)")
		return model
	}

	func registerHuggingFaceModel(_ reference: HuggingFaceModelReference, folder: URL) throws
		-> CustomWhisperModel
	{
		guard !containsHuggingFace(reference) else {
			throw CustomModelError.alreadyAdded("\(reference.repo)/\(reference.variant)")
		}
		try CustomModelValidator.validate(folder: folder)
		let slug = uniqueSlug(for: "\(reference.repo)-\(reference.variant)")
		let model = CustomWhisperModel(
			id: CustomWhisperModel.idPrefix + slug,
			displayName: reference.variant,
			source: .huggingFace(repo: reference.repo, variant: reference.variant),
			folderPath: folder.path,
			addedAt: Date()
		)
		models.append(model)
		save()
		AppLogger.shared.transcriber.log("Registered custom model \(model.id) at \(folder.path)")
		return model
	}

	func remove(id: String) throws {
		guard let index = models.firstIndex(where: { $0.id == id }) else {
			throw CustomModelError.notFound(id)
		}
		let model = models[index]
		if isOwned(model.folderURL), FileManager.default.fileExists(atPath: model.folderPath) {
			try FileManager.default.removeItem(at: model.folderURL)
		}
		models.remove(at: index)
		save()
		AppLogger.shared.transcriber.log("Removed custom model \(id)")
	}

	private func isOwned(_ url: URL) -> Bool {
		let path = url.standardizedFileURL.path
		return ownedRoots.contains { root in
			let rootPath = root.standardizedFileURL.path
			return path.hasPrefix(rootPath + "/")
		}
	}

	private func load() {
		guard let data = defaults.data(forKey: Self.storageKey) else { return }
		do {
			models = try JSONDecoder().decode([CustomWhisperModel].self, from: data)
		} catch {
			AppLogger.shared.transcriber.error("Failed to decode custom models: \(error)")
		}
	}

	private func save() {
		do {
			defaults.set(try JSONEncoder().encode(models), forKey: Self.storageKey)
		} catch {
			AppLogger.shared.transcriber.error("Failed to encode custom models: \(error)")
		}
	}
}
