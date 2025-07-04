# CI/CD Setup Guide for Whispera

This document explains how to set up the automated CI/CD pipeline for Whispera using GitHub Actions.

## Overview

The CI/CD pipeline provides:
- **Automated testing** on every PR
- **Automated releases** when you push tags
- **Code signing and notarization** with Apple
- **DMG distribution** via GitHub Releases

## 🔐 Required GitHub Repository Secrets

### Step 1: Obtain Your Apple Developer Credentials

You'll need these from your Apple Developer account:

1. **Apple ID**: Your Apple developer account email
2. **App-Specific Password**: Generate at [appleid.apple.com](https://appleid.apple.com)
3. **Team ID**: Found in Apple Developer account settings
4. **Developer ID Certificate**: Export from Keychain Access

### Step 2: Export Your Developer ID Certificate

1. Open **Keychain Access** on your Mac
2. Find your "Developer ID Application" certificate
3. Right-click → "Export..."
4. Save as `.p12` file with a password
5. Convert to base64:
   ```bash
   base64 -i YourCert.p12 | pbcopy
   ```

### Step 3: Set Up GitHub Repository Secrets

Go to your GitHub repository → Settings → Secrets and variables → Actions

Add these **Repository secrets**:

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `APPLE_ID` | Your Apple ID email | `developer@example.com` |
| `APP_SPECIFIC_PASSWORD` | App-specific password from Apple | `abcd-efgh-ijkl-mnop` |
| `TEAM_ID` | Your Apple Developer Team ID | `NK28QT38A3` |
| `DEVELOPER_ID_P12` | Base64 encoded certificate | `MIIKs...` (very long) |
| `DEVELOPER_ID_PASSWORD` | Certificate password | `your-cert-password` |
| `KEYCHAIN_PASSWORD` | Temporary keychain password | `ci-temp-password-123` |

### Step 4: Verify Setup

After setting up secrets, the workflows will be available:

- **PR Testing**: Runs automatically on pull requests
- **Release**: Triggers when you push a version tag

## 🚀 How to Create a Release

### Option 1: Tag-Based Release (Recommended)

```bash
# Create and push a version tag
git tag v1.0.3
git push origin v1.0.3
```

This automatically:
1. Bumps version in project files
2. Builds and signs the app
3. Notarizes with Apple
4. Creates GitHub release with DMG

### Option 2: Manual Release

1. Go to GitHub → Actions → "Release Whispera"
2. Click "Run workflow"
3. Enter version number (e.g., `1.0.3`)
4. Click "Run workflow"

## 📋 What Each Workflow Does

### Build and Test (`build-test.yml`)

**Triggers**: Every PR and push to main/develop

**Steps**:
- ✅ Builds the app (unsigned)
- ✅ Runs unit tests
- ✅ Runs UI tests (with error tolerance)
- ✅ Code quality checks
- ✅ Comments PR with results

### Release (`release.yml`)

**Triggers**: Version tags (`v*.*.*`) or manual dispatch

**Steps**:
- 🔢 Bumps version numbers
- 🔐 Sets up secure keychain
- 🔨 Builds and archives app
- 🔏 Signs with Developer ID
- 📤 Notarizes with Apple
- 💿 Creates DMG
- 🚀 Creates GitHub release

## 🛠️ Troubleshooting

### Common Issues

**"No Developer ID certificate found"**
- Verify `DEVELOPER_ID_P12` secret is set correctly
- Check certificate is not expired
- Ensure certificate includes private key

**"Notarization failed"**
- Verify Apple ID credentials
- Check app has all required entitlements
- Ensure app is properly signed

**"Build failed"**
- Check unit/UI tests pass locally
- Verify Xcode project builds without errors
- Review build logs in Actions tab

### Debug Steps

1. **Check secrets**: Ensure all 6 secrets are set in repository settings
2. **Review logs**: Go to Actions tab → failed workflow → review detailed logs
3. **Test locally**: Run `scripts/bump-version.sh 1.0.0` to test version bumping
4. **Verify certificates**: Check your Developer ID certificate is valid

### Getting Help

- Check the [Actions tab](../../actions) for detailed logs
- Review [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- Ensure your Apple Developer account is in good standing

## 🔄 Maintenance

### Updating Secrets

If you need to rotate credentials:
1. Generate new app-specific password
2. Update the corresponding secret in GitHub
3. Next release will use new credentials

### Modifying Workflows

The workflow files are in `.github/workflows/`:
- Edit locally and commit changes
- Test changes on a feature branch first
- Workflows update automatically when merged

## 📊 Release Artifacts

Each successful release creates:
- **DMG file**: For easy distribution to users
- **Zipped app**: Alternative download format
- **Release notes**: Auto-generated from git commits

Users can download directly from the [Releases page](../../releases).

---

## 🎯 Quick Start Checklist

- [ ] Set up all 6 GitHub repository secrets
- [ ] Verify Developer ID certificate is valid
- [ ] Test with a sample tag: `git tag v1.0.0-test && git push origin v1.0.0-test`
- [ ] Check release appears in [Actions](../../actions)
- [ ] Download and test the generated DMG
- [ ] Delete test tag: `git tag -d v1.0.0-test && git push origin :v1.0.0-test`

Your automated pipeline is ready! 🎉