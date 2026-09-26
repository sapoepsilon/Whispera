# Release Scripts

## Release flow

Releases are cut by `.github/workflows/release.yml`. Push a `vX.Y.Z` tag (or run the workflow with a version) and it:

1. checks that the version is `MAJOR.MINOR.PATCH`, then runs `scripts/bump-version.sh X.Y.Z` on the runner, so the tag is the source of truth for the version and the run number becomes the build,
2. imports the Developer ID certificate into a temporary keychain with `scripts/setup-keychain.sh`,
3. archives and exports the app with `xcodebuild` (steps in the workflow itself, using `scripts/ExportOptions-dev.plist`),
4. signs, notarizes, staples and packages it with `scripts/release-distribute-ci.sh`, which also writes a Sparkle-signed `appcast.xml` (with `SPARKLE_PRIVATE_KEY` set it stops the release when the EdDSA signature is missing or `sign_update` is not found, and takes `minimumSystemVersion` from the built app's `LSMinimumSystemVersion`),
5. writes the release body with `scripts/release-notes.sh` and publishes the GitHub release with `Whispera.dmg`, `Whispera-X.Y.Z.dmg` and `Whispera.app.zip`,
6. commits `appcast.xml` to `main`, but only one generated and signed for this version,
7. in a separate `homebrew-cask` job, bumps `Casks/whispera.rb` on `main` with `scripts/update-cask.sh X.Y.Z`, hashing the published DMG. A failure there fails that job with a warning and a run summary, without touching the release or the appcast.

`release-distribute-ci.sh` does not build: it expects the exported app at `build/Release/Whispera.app`.

## Build numbers

`bump-version.sh` sets `MARKETING_VERSION` / `CFBundleShortVersionString` to the version and `CURRENT_PROJECT_VERSION` / `CFBundleVersion` to `BUILD_NUMBER` when set, else `GITHUB_RUN_NUMBER` on CI, else the current build + 1. The released build is the workflow's run number (the appcast records it as `sparkle:version`). Keep the tree at the latest released version and build, so local builds report the same version as the cask and Sparkle does not offer them the release they already are:

```bash
BUILD_NUMBER=36 ./scripts/bump-version.sh 1.3.2 --commit   # use the appcast's sparkle:version
```

A plain `./scripts/bump-version.sh X.Y.Z --commit` increments the build instead, which is ahead of the released build.

## Releasing by hand

There is no complete local release script in this repository. `release-distribute.template.sh` holds only the credential variables of the maintainer's private `release-distribute.sh`, which is gitignored and not published. To release from a checkout, run the same steps as the workflow, with the Developer ID certificate in your keychain:

```bash
./scripts/bump-version.sh X.Y.Z
xcodebuild -project Whispera.xcodeproj -scheme Whispera -configuration Release \
  -archivePath build/Release/Whispera.xcarchive -destination "generic/platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO archive
xcodebuild -exportArchive -archivePath build/Release/Whispera.xcarchive \
  -exportPath build/Release -exportOptionsPlist scripts/ExportOptions-dev.plist
SIGNING_KEYCHAIN=login.keychain-db APPLE_ID=... APP_SPECIFIC_PASSWORD=... TEAM_ID=... \
  SPARKLE_PRIVATE_KEY=... ./scripts/release-distribute-ci.sh
```

`SIGNING_KEYCHAIN` names the keychain that holds the Developer ID Application identity (the workflow uses the temporary one from `setup-keychain.sh`). Without `SPARKLE_PRIVATE_KEY` no appcast is written. This sequence is what CI runs; it has not been exercised outside CI. Always test the DMG, including the microphone and Accessibility prompts, before distributing it. After uploading the DMGs to a GitHub release, commit `appcast.xml` and run `./scripts/update-cask.sh X.Y.Z` (see below).

## Files

- `bump-version.sh` - Sets the version and build number
- `setup-keychain.sh` - Imports the Developer ID certificate into a temporary keychain (CI)
- `release-distribute-ci.sh` - Signs, notarizes, staples and packages an exported app and writes the appcast
- `release-distribute.template.sh` - Credential variables of the private local script (tracked in git)
- `release-distribute.sh` - The private local script (NOT tracked in git)
- `release-notes.sh` - Writes the GitHub release body that What's New shows
- `update-cask.sh` - Bumps `Casks/whispera.rb` to a released version
- `ExportOptions.plist`, `ExportOptions-dev.plist` - Export configurations (the workflow uses `ExportOptions-dev.plist`)
- `generate-sparkle-keys.sh` - Creates the Sparkle EdDSA key pair (see `docs/sparkle-keys.md`)
- `export-cert-for-ci.sh`, `check-certificates.sh`, `test-keychain-setup.sh` - Certificate and keychain helpers for setting up CI (see `docs/CICD_SETUP.md`)
- `qa-record.sh`, `qa-worktree.sh` - QA helpers

## Release notes

The GitHub release body is what the app shows in What's New after an update, so it is written for users. Put curated notes in `release-notes/vX.Y.Z.md` before tagging; `scripts/release-notes.sh X.Y.Z` (run by the release workflow) uses that file as the "What's New" section and adds the download and system requirement sections. Without the file it falls back to the `feat`, `fix` and `perf` commit subjects since the previous tag, skipping merges and developer-only scopes.

## Homebrew Cask

`Casks/whispera.rb` is served straight from this repository, which doubles as a tap:

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

The release workflow bumps the cask automatically in its `homebrew-cask` job. For a release published by hand (the DMG must be attached as `Whispera-<version>.dmg`), bump the cask and commit it:

```bash
./scripts/update-cask.sh 1.3.3                 # downloads the published DMG
./scripts/update-cask.sh 1.3.3 path/to/Whispera-1.3.3.dmg   # or hashes a local copy
```

The script writes the new `version` and `sha256` and runs `brew style` (set `CASK_SKIP_STYLE=1` to skip it). Before committing, check the cask end to end:

```bash
brew tap-new --no-git local/whisperatest
cp Casks/whispera.rb "$(brew --repository local/whisperatest)/Casks/"
brew audit --cask --online --strict local/whisperatest/whispera
brew livecheck --cask local/whisperatest/whispera
brew untap local/whisperatest
```

`livecheck` reads the Sparkle appcast, so the same cask can later be submitted to `homebrew/cask` unchanged (see https://docs.brew.sh/Adding-Software-to-Homebrew#casks).
