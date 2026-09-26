# Release Scripts

## Release flow

Releases are cut by `.github/workflows/release.yml`. Push a `vX.Y.Z` tag (or run the workflow with a version) and it:

1. runs `scripts/bump-version.sh X.Y.Z` on the runner, so the tag is the source of truth for the version,
2. builds, signs and notarizes via `scripts/release-distribute-ci.sh`, which also writes `appcast.xml`,
3. publishes the GitHub release with `Whispera.dmg`, `Whispera-X.Y.Z.dmg` and `Whispera.app.zip`,
4. commits `appcast.xml` to `main`, then bumps `Casks/whispera.rb` on `main` with `scripts/update-cask.sh X.Y.Z dist/Whispera-X.Y.Z.dmg` in a separate step, so a cask failure never holds back the Sparkle appcast.

Keep `MARKETING_VERSION` / `CFBundleShortVersionString` and `CURRENT_PROJECT_VERSION` / `CFBundleVersion` in the tree at the latest released version and build (the workflow uses the run number as the build, which the appcast records as `sparkle:version`), so local builds report the same version as the cask and Sparkle does not offer them the release they already are. `./scripts/bump-version.sh X.Y.Z --commit` bumps both.

The manual path below (`release-distribute.sh`) builds and notarizes a DMG locally; after uploading it to a GitHub release, run `./scripts/update-cask.sh X.Y.Z` and commit the cask yourself.

## Setup for local distribution

1. **Copy the template:**
   ```bash
   cp release-distribute.template.sh release-distribute.sh
   ```

2. **Edit `release-distribute.sh` with your credentials:**
   - Replace `DEVELOPER_ID` with your actual Developer ID Application certificate
   - Replace `APPLE_ID` with your Apple ID email
   - Replace `APP_SPECIFIC_PASSWORD` with your app-specific password
   - Replace `TEAM_ID` with your team identifier

3. **Make it executable:**
   ```bash
   chmod +x release-distribute.sh
   ```

## Usage

Run the complete build and distribution process:

```bash
./scripts/release-distribute.sh
```

This script will:
1. Clean previous builds
2. Build and archive the app
3. Export the app bundle
4. Sign with proper entitlements
5. Notarize with Apple
6. Create a DMG for distribution

## Important Notes

- The `release-distribute.sh` file is excluded from git for security
- Always test the final DMG before distributing
- Make sure your certificates are installed in Keychain
- Verify microphone permissions work in the final build

## Files

- `release-distribute.template.sh` - Template file (tracked in git)
- `release-distribute.sh` - Your actual script with credentials (NOT tracked in git)
- `release-distribute-ci.sh` - Env-driven variant used by the release workflow
- `update-cask.sh` - Bumps `Casks/whispera.rb` to a released version
- `ExportOptions-dev.plist` - Export configuration
- `release-notes.sh` - Writes the GitHub release body that What's New shows

## Release notes

The GitHub release body is what the app shows in What's New after an update, so it is written for users. Put curated notes in `release-notes/vX.Y.Z.md` before tagging; `scripts/release-notes.sh X.Y.Z` (run by the release workflow) uses that file as the "What's New" section and adds the download and system requirement sections. Without the file it falls back to the `feat`, `fix` and `perf` commit subjects since the previous tag, skipping merges and developer-only scopes.

## Homebrew Cask

`Casks/whispera.rb` is served straight from this repository, which doubles as a tap:

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

The release workflow bumps the cask automatically. For a release published by hand (the DMG must be attached as `Whispera-<version>.dmg`), bump the cask and commit it:

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
