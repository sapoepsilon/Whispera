import Foundation
import Testing
import WhisperKit

@testable import Whispera

struct HuggingFaceModelReferenceTests {

	@Test func parsesRepoAndVariant() {
		let ref = HuggingFaceModelReference.parse(repoInput: " owner/my-repo ", variant: "whisper_small.en ")
		#expect(ref == HuggingFaceModelReference(repo: "owner/my-repo", variant: "whisper_small.en"))
	}

	@Test func parsesFolderLinkWithoutSeparateVariant() {
		let ref = HuggingFaceModelReference.parse(
			repoInput: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny",
			variant: "")
		#expect(ref?.repo == "argmaxinc/whisperkit-coreml")
		#expect(ref?.variant == "openai_whisper-tiny")
		#expect(ref?.isBuiltInRepository == true)
	}

	@Test func explicitVariantWinsOverLink() {
		let ref = HuggingFaceModelReference.parse(
			repoInput: "huggingface.co/owner/repo/tree/main/a", variant: "b")
		#expect(ref == HuggingFaceModelReference(repo: "owner/repo", variant: "b"))
	}

	@Test(arguments: [
		("owner", "v"),
		("owner/repo", ""),
		("owner/repo/extra", "v"),
		("owner/repo", "../escape"),
		("own er/repo", "v"),
		("https://huggingface.co/owner/repo/tree/main", ""),
	])
	func rejectsInvalidInput(repo: String, variant: String) {
		#expect(HuggingFaceModelReference.parse(repoInput: repo, variant: variant) == nil)
	}
}

@MainActor
struct CustomModelStoreTests {

	private let root: URL
	private let suiteName: String
	private let defaults: UserDefaults

	init() throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CustomModelStoreTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		suiteName = "CustomModelStoreTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)!
	}

	private func makeStore() -> CustomModelStore {
		CustomModelStore(
			defaults: defaults,
			importRoot: root.appendingPathComponent("custom", isDirectory: true),
			ownedRoots: [root.appendingPathComponent("owned", isDirectory: true)]
		)
	}

	private func makeModelFolder(named name: String, in parent: URL, components: [String]? = nil)
		throws -> URL
	{
		let folder = parent.appendingPathComponent(name, isDirectory: true)
		for component in components ?? CustomModelValidator.requiredComponents {
			let bundle = folder.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
			try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
			try Data("weights".utf8).write(to: bundle.appendingPathComponent("weights.bin"))
		}
		return folder
	}

	@Test func validatorReportsMissingComponents() throws {
		let folder = try makeModelFolder(
			named: "partial", in: root, components: ["AudioEncoder"])
		#expect(
			CustomModelValidator.missingComponents(in: folder) == ["MelSpectrogram", "TextDecoder"])
		#expect(throws: CustomModelError.missingComponents(["MelSpectrogram", "TextDecoder"])) {
			try CustomModelValidator.validate(folder: folder)
		}
	}

	@Test func validatorAcceptsMlpackage() throws {
		let folder = root.appendingPathComponent("pkg", isDirectory: true)
		for component in CustomModelValidator.requiredComponents {
			try FileManager.default.createDirectory(
				at: folder.appendingPathComponent("\(component).mlpackage"),
				withIntermediateDirectories: true)
		}
		try CustomModelValidator.validate(folder: folder)
	}

	@Test func validatorRejectsFiles() throws {
		let file = root.appendingPathComponent("file.bin")
		try Data().write(to: file)
		#expect(throws: CustomModelError.notADirectory(file.path)) {
			try CustomModelValidator.validate(folder: file)
		}
	}

	@Test func importCopiesFolderAndPersists() async throws {
		let source = try makeModelFolder(named: "My Model v2", in: root)
		let store = makeStore()

		let model = try await store.importLocalFolder(source)

		#expect(model.id == "custom:my-model-v2")
		#expect(model.displayName == "My Model v2")
		#expect(model.folderURL.deletingLastPathComponent().lastPathComponent == "custom")
		#expect(CustomModelValidator.missingComponents(in: model.folderURL).isEmpty)
		#expect(store.isAvailable(id: model.id))

		let reloaded = makeStore()
		#expect(reloaded.models == [model])
	}

	@Test func importingTheSameNameTwiceGetsAUniqueID() async throws {
		let source = try makeModelFolder(named: "dup", in: root)
		let store = makeStore()

		let first = try await store.importLocalFolder(source)
		let second = try await store.importLocalFolder(source)

		#expect(first.id == "custom:dup")
		#expect(second.id == "custom:dup-2")
	}

	@Test func importRejectsInvalidFolder() async throws {
		let source = try makeModelFolder(named: "bad", in: root, components: [])
		let store = makeStore()
		await #expect(throws: CustomModelError.self) {
			_ = try await store.importLocalFolder(source)
		}
		#expect(store.models.isEmpty)
	}

	@Test func removeDeletesOwnedCopy() async throws {
		let source = try makeModelFolder(named: "gone", in: root)
		let store = makeStore()
		let model = try await store.importLocalFolder(source)

		try store.remove(id: model.id)

		#expect(!FileManager.default.fileExists(atPath: model.folderPath))
		#expect(FileManager.default.fileExists(atPath: source.path))
		#expect(makeStore().models.isEmpty)
	}

	@Test func registerHuggingFaceRejectsDuplicatesAndKeepsForeignFolders() throws {
		let outside = try makeModelFolder(named: "variant-a", in: root)
		let store = makeStore()
		let reference = HuggingFaceModelReference(repo: "owner/repo", variant: "variant-a")

		let model = try store.registerHuggingFaceModel(reference, folder: outside)
		#expect(model.id == "custom:owner-repo-variant-a")
		#expect(throws: CustomModelError.alreadyAdded("owner/repo/variant-a")) {
			_ = try store.registerHuggingFaceModel(reference, folder: outside)
		}

		try store.remove(id: model.id)
		#expect(FileManager.default.fileExists(atPath: outside.path))
	}

	@Test func missingFolderMakesModelUnavailable() throws {
		let folder = try makeModelFolder(
			named: "variant-b", in: root.appendingPathComponent("owned"))
		let store = makeStore()
		let model = try store.registerHuggingFaceModel(
			HuggingFaceModelReference(repo: "o/r", variant: "variant-b"), folder: folder)

		try FileManager.default.removeItem(at: folder)

		#expect(!store.isAvailable(id: model.id))
		#expect(store.availableModels.isEmpty)
	}

	@Test func slugSanitizesNames() {
		#expect(CustomModelStore.slug(for: "Owner/Repo Name!") == "owner-repo-name")
		#expect(CustomModelStore.slug(for: "///") == "model")
	}
}

/// Loads a real WhisperKit model through the custom-folder path and transcribes speech with it.
@MainActor
struct CustomModelTranscriptionTests {

	nonisolated static let whisperaModels = FileManager.default.urls(
		for: .applicationSupportDirectory, in: .userDomainMask
	)[0].appendingPathComponent("Whispera", isDirectory: true)

	nonisolated static let tinyModel = whisperaModels.appendingPathComponent(
		"models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en", isDirectory: true)

	nonisolated static var tinyModelPresent: Bool {
		CustomModelValidator.missingComponents(in: tinyModel).isEmpty
	}

	@Test(.enabled(if: tinyModelPresent, "needs openai_whisper-tiny.en downloaded"))
	func importedFolderTranscribesSpeech() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("CustomModelTranscription-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let suite = "CustomModelTranscriptionTests.\(UUID().uuidString)"
		let store = CustomModelStore(
			defaults: UserDefaults(suiteName: suite)!,
			importRoot: root.appendingPathComponent("custom"),
			ownedRoots: [])

		let model = try await store.importLocalFolder(Self.tinyModel, displayName: "Tiny import")
		let audio = try SpeechFixture.make(
			"The quick brown fox jumps over the lazy dog.", in: root)

		let config = model.whisperKitConfig(
			downloadBase: Self.whisperaModels,
			computeOptions: ComputeUnitPreference.automatic.whisperKitComputeOptions)
		let whisperKit = try await WhisperKit(config)
		let results = try await whisperKit.transcribe(audioPath: audio.path)
		let text = results.map(\.text).joined(separator: " ").lowercased()

		#expect(text.contains("fox"))
		#expect(text.contains("dog"))
	}
}

enum SpeechFixture {
	static func make(_ sentence: String, in directory: URL) throws -> URL {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent("speech-\(UUID().uuidString).wav")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
		process.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", sentence]
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CocoaError(.fileWriteUnknown)
		}
		return url
	}
}
