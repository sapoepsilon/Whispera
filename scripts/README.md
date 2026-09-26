# Release Scripts

## Setup for Distribution

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
- `build-release.sh` - Development build script
- `ExportOptions-dev.plist` - Export configuration
## Homebrew Cask

`Casks/whispera.rb` is served straight from this repository, which doubles as a tap:

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

After a release is published (the DMG must be attached as `Whispera-<version>.dmg`), bump the cask and commit it:

```bash
./scripts/update-cask.sh 1.3.3
```

The script downloads the release DMG, writes the new `version` and `sha256`, and runs `brew style`. Before committing, check the cask end to end:

```bash
brew tap-new --no-git local/whisperatest
cp Casks/whispera.rb "$(brew --repository local/whisperatest)/Casks/"
brew audit --cask --online --strict local/whisperatest/whispera
brew livecheck --cask local/whisperatest/whispera
brew untap local/whisperatest
```

`livecheck` reads the Sparkle appcast, so the same cask can later be submitted to `homebrew/cask` unchanged (see https://docs.brew.sh/Adding-Software-to-Homebrew#casks).
