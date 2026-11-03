# Vendored Swift packages

Every Swift package the Whispera app and `LinkHelper` build against lives in this directory. The
Xcode project references each one as an `XCLocalSwiftPackageReference`, `LinkHelper/Package.swift`
uses `.package(path: "../Packages/...")`, and every manifest here references its own dependencies
by local path, so resolving the project touches no network and no remote repository.

Each package is the upstream tree at the exact commit below with files deleted and the manifest
edited. No other file was changed, except the local modifications listed under "Local
modifications" below. `vendored-sources.txt` holds the same pins, the exact deletion list and the
local files in machine-readable form, and `scripts/verify-vendored.sh` re-fetches every upstream
and prints anything that differs beyond those deletions, the manifests and the local files
(`--manifests` shows the manifest diffs).

Directory names match the upstream package identities (`whispera-components`, `swift-transformers`,
...), so every `.product(name:package:)` reference kept its original spelling.

Dropped from the graph entirely: `swift-argument-parser` (only the WhisperKit CLI used it),
`swift-asn1` (only swift-crypto's CryptoExtras used it) and `swift-snapshot-testing` (only
swift-markdown-ui's tests used it).

| Package | Upstream | Version | Commit | License | Removed | Package.swift edits |
|---|---|---|---|---|---|---|
| whispera-components | https://github.com/sapoepsilon/whispera-components (private) | unversioned | `af7dd7fc549cede4d5270b390b6b09530aacec04` | none in the repo (owner's code) | web/, docs/, tokens/, scripts/, pnpm/package files, result and brief notes, apple/Tests, and the WhisperaComponents, WhisperaDictationUI, DictationDemo, DictationChecks, DictationSelfTest, PackageChecks, PackageSelfTest targets | dropped those products and targets and every test target |
| agent-tui-protocol | https://github.com/sapoepsilon/agent-tui-protocol | unversioned | `a9a23135b784c0621af6507c2de08d4506d66e76` | MIT | Tests/ (with Fixtures), .gitignore | dropped the test target |
| agent-herdr | https://github.com/sapoepsilon/agent-herdr | unversioned | `3dff1f2352fea16160ec8f332d45ee92bc201c08` | MIT | Tests/, Package.resolved, .gitignore | agent-tui-protocol by path; dropped the test target |
| agent-tmux | https://github.com/sapoepsilon/agent-tmux | unversioned | `f52f9be2063e4a2d0225e1ab3cc7100b5b6d6c1e` | MIT | Tests/, Package.resolved, .gitignore | agent-tui-protocol by path; dropped the test target |
| WhisperKit | https://github.com/argmaxinc/WhisperKit | `main` | `3817d2833f73ceb30586cb285e0e0439a3860536` | MIT | Sources/TTSKit, Sources/SpeakerKit, Sources/WhisperKitCLI, Tests, Examples, fastlane, scripts, Makefile, BENCHMARKS/CONTRIBUTING, Package.resolved, dotfiles | WhisperKit product only (ArgmaxCore + WhisperKit targets); removed the CLI's server-mode packages (vapor, swift-openapi-*) and swift-argument-parser; swift-transformers by path |
| swift-transformers | https://github.com/huggingface/swift-transformers.git | 1.1.9 | `150169bfba0889c229a2ce7494cf8949f18e6906` | Apache-2.0 | Sources/Generation, Sources/Models, Tests, Examples, media, dotfiles | Hub and Tokenizers products only (dropped Transformers, Generation, Models, test targets); swift-jinja, swift-collections, swift-crypto, yyjson by path |
| swift-jinja | https://github.com/huggingface/swift-jinja.git | 2.3.2 | `f731f03bf746481d4fda07f817c3774390c4d5b9` | Apache-2.0 | Tests, Package.resolved, dotfiles | swift-collections by path; dropped the test target |
| swift-collections | https://github.com/apple/swift-collections.git | 1.4.0 | `8d9834a6189db730f6264db7556a7ffb751e99ee` | Apache-2.0 with Runtime Library Exception | every module except OrderedCollections and InternalCollectionsUtilities, Tests, Benchmarks, Documentation, Utils, Xcode, cmake/CMakeLists, Package@swift-6.0.swift, dotfiles | target list cut to InternalCollectionsUtilities + OrderedCollections; settings, traits and availability macros untouched |
| swift-crypto | https://github.com/apple/swift-crypto.git | 4.3.0 | `fa308c07a6fa04a727212d793e761460e41049c3` | Apache-2.0 (NOTICE.txt kept) | CCryptoBoringSSL, CCryptoBoringSSLShims, CryptoBoringWrapper, CXKCP, CXKCPShims (linked only on Linux/Android/Windows/WASI/OpenBSD), CryptoExtras, _CryptoExtras, crypto-shasum, Tests, Benchmarks, cmake, dev, scripts, dotfiles | Crypto target only, with the Apple-platform settings (`CRYPTO_IN_SWIFTPM`, no dependencies: it re-exports CryptoKit); swift-asn1 dependency removed |
| yyjson | https://github.com/ibireme/yyjson.git | 0.12.0 | `8b4a38dc994a110abaec8a400615567bd996105f` | MIT | doc, fuzz, test, misc, cmake/CMakeLists, CHANGELOG, yyjson.pc.in, dotfiles | none |
| FluidAudio | https://github.com/FluidInference/FluidAudio | 0.9.1 | `915a392a3b214205fcf4860cc3608bde35891d03` | Apache-2.0 (ThirdPartyLicenses/ kept) | Frameworks/ESpeakNG.xcframework, Sources/FluidAudioTTS, Sources/FluidAudioCLI, Tests, Documentation, banner.png, podspec, benchmark script, agent/plan/report notes, dotfiles | FluidAudio product only (dropped FluidAudioTTS, ESpeakNG binary target, CLI, tests) |
| YouTubeKit | https://github.com/alexeichhorn/YouTubeKit | 0.4.7 | `4140995e3485cd691fadb67b2820dbab2d3d84e9` | MIT | Tests, Scripts, dotfiles | dropped the test target |
| swift-markdown-ui | https://github.com/gonzalezreal/swift-markdown-ui | 2.4.1 | `5f613358148239d0292c0cef674a3c2314737f9e` | MIT | Tests, Examples, Sources/MarkdownUI/Documentation.docc, Makefile, Package.resolved, dotfiles | NetworkImage and swift-cmark by path; dropped swift-snapshot-testing and the test target |
| NetworkImage | https://github.com/gonzalezreal/NetworkImage | 6.0.1 | `2849f5323265386e200484b0d0f896e73c3411b9` | MIT | Tests, Demo, Makefile, dotfiles | dropped the test target (Package.swift and Package@swift-6.0.swift) |
| swift-cmark | https://github.com/swiftlang/swift-cmark | 0.7.1 | `5d9bdaa4228b381639fff09403e39a04926e2dbe` | BSD-2-Clause (COPYING) | bin, api_test, test, bench, fuzz, man, tools, wrappers, data, cmake/CMakeLists, Makefiles, CI and Windows build files, dotfiles | cmark-gfm and cmark-gfm-extensions products only (dropped cmark-gfm-bin, api_test) |
| Sparkle | https://github.com/sparkle-project/Sparkle (release asset `Sparkle-for-Swift-Package-Manager.zip`) | 2.9.0 | `21d8df80440b1ca3b65fa82e40782f1e5a9e6ba2` (tag 2.9.0) | MIT plus bundled notices (LICENSE) | CHANGELOG, INSTALL, SampleAppcast.xml, bin/BinaryDelta, bin/generate_appcast, bin/old_dsa_scripts | new manifest: `binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")` in place of upstream's `url:`/`checksum:` target |

## Sparkle

- Asset: https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-for-Swift-Package-Manager.zip
- SHA-256: `44a0d5a00d5bfb6c2ad1755a92b694d948876d61ad44f35a0119eb0e7ace4b65`, equal to the
  `checksum` in Sparkle's own Package.swift at tag 2.9.0.
- `codesign -dv --verbose=2 Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`:

  ```
  Identifier=org.sparkle-project.Sparkle
  Format=bundle with Mach-O universal (x86_64 arm64)
  CodeDirectory v=20500 size=1116 flags=0x10002(adhoc,runtime) hashes=28+3 location=embedded
  Signature=adhoc
  Info.plist entries=20
  TeamIdentifier=not set
  Runtime Version=26.2.0
  Sealed Resources version=2 rules=13 files=78
  Internal requirements count=0 size=12
  ```

  Ad-hoc signed with the hardened runtime, which is how Sparkle ships its Swift Package Manager
  build; `codesign --verify --deep --strict` passes. Xcode embeds it and
  `scripts/release-distribute-ci.sh` re-signs the framework, its XPC services and helpers with the
  Developer ID. `bin/sign_update` and `bin/generate_keys` are ad-hoc signed as well.
- `bin/sign_update` (used by `scripts/release-distribute-ci.sh`) and `bin/generate_keys` (used by
  `scripts/generate-sparkle-keys.sh` and `docs/sparkle-keys.md`) are kept from the same zip.
- The xcframework's `dSYMs` (about 20 MB of the 25 MB) are kept because its Info.plist names them
  in `DebugSymbolsPath`; `Packages/.gitignore` re-includes `*.dSYM`, which the root .gitignore skips.

## Local modifications

Files changed or added here on purpose, not yet upstream. Each has a `local` line in
`vendored-sources.txt`; the verifier lists it as `LOCAL` and fails on an undocumented change.

- agent-herdr: `Sources/WhisperaHerdr/HerdrCore.swift` (added). herdr-core (`hc`) support: the
  `hc:` agent id encoding, the agent projection of hc's `Terminal` object, the hc TUI provider
  and `HerdrCoreAskTerminal`. No existing file of the package changed. Upstream it, then bump the
  pin and drop the `local` line. Its doc comments use generic host names
  (`mac-b`); keep them generic when upstreaming.
- whispera-components: `apple/Sources/WhisperaLink/LinkMessage.swift` (changed). `LinkOffer`
  carries the optional `allow_lan_http` flag the iOS app reads to decide whether the Mac's plain
  `http://` LAN addresses may be used directly, and `issued_at` (Unix seconds) so the phone can
  refuse a rolled-back offer; the same fields as the iOS app's copy. Drop the
  `local` line once upstream has it.
- whispera-components: `apple/Sources/WhisperaDictation/RealtimeProtocol.swift` (changed). One
  doc comment no longer names a private test machine; no code changed. Upstream the
  same wording.
- agent-tui-protocol: `Sources/WhisperaAgents/Asks/ChoiceMenu.swift` and
  `Sources/WhisperaAgents/Asks/AgentAsk.swift` (changed). A menu's prompt id also hashes the
  dialog's full, unclipped text (`contentDigest`, cursor excluded), so two dialogs that differ
  only past a display clip get different ids; `ChoiceMenu.truncated` / `AgentAsk.truncated`
  (JSON `truncated`, false when an older payload leaves it out) say a field was clipped, detail
  lines were dropped, a Codex command goes on below its `$` line, or the 40-line window cut the
  dialog. Upstream both, then drop the `local` lines.

## Updating a package

Fetch the new upstream commit, copy it over `Packages/<dir>`, re-apply the `rm` lines from
`vendored-sources.txt`, carry the manifest edits and any local modifications over, update the pin in `vendored-sources.txt`
and in the table above, then build and run `scripts/verify-vendored.sh <dir>`.
