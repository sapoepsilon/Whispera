import Foundation

/// The user's recipes, on disk as one JSON file.
///
/// Local-first and local-only. There is no sync arm, no client to inject, and
/// no flag that turns one on — the version this replaced carried six dead
/// `if usesBackend` branches and two initialiser parameters nothing ever called
/// through. A host that wants sync layers it on top of this store rather than
/// inside it.
@MainActor
public final class RecipeStore {
	public private(set) var recipes: [Recipe] = []
	public var lastError: String?

	private let fileURL: URL

	/// The storage location is injectable because a test that writes to the real
	/// Application Support directory is a test that can destroy the user's
	/// recipes.
	public init(fileURL: URL? = nil) {
		self.fileURL = fileURL ?? Self.defaultFileURL()
		load()
	}

	public static func defaultFileURL(
		directoryName: String = "Whispera", fileName: String = "recipes.json"
	) -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent(directoryName, isDirectory: true)
		try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
		return base.appendingPathComponent(fileName)
	}

	// MARK: - Persistence

	/// A recipes file that will not decode is left alone rather than overwritten:
	/// whatever is in it is more likely a version this build predates than
	/// garbage, and truncating it would be irreversible.
	private func load() {
		guard let data = try? Data(contentsOf: fileURL) else { return }
		do {
			recipes = try JSONDecoder().decode([Recipe].self, from: data)
		} catch {
			lastError = "Couldn't read your saved commands: \(error.localizedDescription)"
		}
	}

	@discardableResult
	private func persist() -> Bool {
		do {
			try JSONEncoder().encode(recipes).write(to: fileURL, options: .atomic)
			return true
		} catch {
			lastError = "Couldn't save your commands: \(error.localizedDescription)"
			return false
		}
	}

	/// Re-reads the file, for a host that changed it out of band.
	public func reload() {
		recipes = []
		load()
	}

	// MARK: - CRUD

	public func create(_ recipe: Recipe) {
		lastError = nil
		recipes.append(recipe)
		persist()
	}

	public func update(_ recipe: Recipe) {
		lastError = nil
		guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
		recipes[index] = recipe
		persist()
	}

	public func delete(_ recipe: Recipe) {
		lastError = nil
		recipes.removeAll { $0.id == recipe.id }
		persist()
	}

	public func recipe(id: String) -> Recipe? {
		recipes.first { $0.id == id }
	}

	public func match(_ text: String) -> RecipeMatch? {
		RecipeMatcher.match(text: text, recipes: recipes)
	}

	/// Seeds the bundled starter set, and only when there is nothing to lose.
	public func loadDefaults() {
		guard recipes.isEmpty else { return }
		lastError = nil
		recipes = Recipe.localDefaults
		persist()
	}
}
