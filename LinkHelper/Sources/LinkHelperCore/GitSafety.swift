import Foundation

/// How the helper runs `git` in an agent's workspace: a repository the owner did not
/// necessarily write, whose `.git/config` (or `.gitattributes`) could name programs that git
/// runs on its own (an fsmonitor hook, a clean filter, a signature verifier, a hook). Every git
/// the helper starts in a workspace, on this Mac or over ssh, goes through this.
///
/// The user's own global config is kept (`GIT_CONFIG_GLOBAL` is not redirected): it holds
/// `core.excludesFile`, which decides what the code reader treats as ignored, and nothing in it
/// comes from the repository. The system config is skipped; the helper needs nothing from it.
enum GitSafety {
	/// `-c` pairs placed before every subcommand. They outrank every config file, and git hands
	/// them on to the git processes it starts itself.
	static let config: [(key: String, value: String)] = [
		// Empty means off, both for the old hook-path form and the newer bool-or-path form.
		("core.fsmonitor", ""),
		("core.hooksPath", "/dev/null"),
		("protocol.file.allow", "never"),
		// `git log` would run `gpg.program` (repository config) to check each signature.
		("log.showSignature", "false"),
	]

	/// Variables that would point git at another repository, config, program or pager.
	static let unsetVariables = [
		"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
		"GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
		"GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
		"GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_PAGER", "PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
		"GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR",
		"GIT_ATTR_SOURCE", "GIT_REPLACE_REF_BASE", "GIT_NO_REPLACE_OBJECTS", "GIT_TRACE", "GIT_TRACE2",
		"GIT_TRACE2_EVENT", "GIT_TRACE2_PERF",
	]

	static let setVariables: [(name: String, value: String)] = [
		("GIT_CONFIG_NOSYSTEM", "1"),
		("GIT_TERMINAL_PROMPT", "0"),
		("GIT_OPTIONAL_LOCKS", "0"),
	]

	/// `git` arguments with the hardening in front of `arguments`.
	static func arguments(_ arguments: [String]) -> [String] {
		config.flatMap { ["-c", "\($0.key)=\($0.value)"] } + arguments
	}

	/// The environment for a git started directly (not through `shellPrelude`).
	static func environment(_ base: [String: String]) -> [String: String] {
		var environment = base
		for name in unsetVariables { environment[name] = nil }
		for (name, value) in setVariables { environment[name] = value }
		return environment
	}

	/// `/usr/bin/env` arguments that run `git` with `arguments` under the hardened environment,
	/// for `HerdrCLI.spawn`, which passes the helper's own environment on.
	static func envCommand(git: String = "/usr/bin/git", _ arguments: [String]) -> (path: String, arguments: [String]) {
		let unset = unsetVariables.flatMap { ["-u", $0] }
		let set = setVariables.map { "\($0.name)=\($0.value)" }
		return ("/usr/bin/env", unset + set + [git] + Self.arguments(arguments))
	}

	/// POSIX `sh` that the workspace scripts start with: the hardened environment, and a `git`
	/// function that adds the `-c` pairs and switches off the filter drivers the repository's
	/// own config defines (a `clean` filter runs whenever `status` or `diff` reads a file).
	/// The user's global filters (Git LFS) keep working unless the repository redefines them.
	/// A repository filter whose name a `-c` pair cannot carry gets no git at all.
	static var shellPrelude: String {
		let quote = CodeReader.shellQuote
		let unset = "unset " + unsetVariables.joined(separator: " ")
		let export = "export " + setVariables.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
		let flags = config.map { "-c " + quote("\($0.key)=\($0.value)") }.joined(separator: " ")
		return """
			\(unset)
			\(export)
			git() {
				__wl_filters=$( { command git config --local --includes --name-only --get-regexp '^filter[.]'; command git config --worktree --includes --name-only --get-regexp '^filter[.]'; } 2>/dev/null | sed -n 's/^filter[.]\\(.*\\)[.][^.]*$/\\1/p' | sort -u)
				if [ -n "$__wl_filters" ]; then
					while IFS= read -r __wl_filter; do
						case $__wl_filter in *[!A-Za-z0-9_.-]*) return 128 ;; esac
						set -- -c "filter.$__wl_filter.clean=" -c "filter.$__wl_filter.smudge=" -c "filter.$__wl_filter.process=" -c "filter.$__wl_filter.required=false" "$@"
					done <<-__WL_FILTERS
					$__wl_filters
					__WL_FILTERS
				fi
				command git \(flags) "$@"
			}

			"""
	}
}
