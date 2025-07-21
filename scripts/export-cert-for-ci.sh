#!/bin/bash

# Certificate Export Helper for Whispera CI
# Helps export your Developer ID certificate and set up GitHub secrets

set -e

CERT_NAME="Developer ID Application: Ismatulla Mansurov (NK28QT38A3)"
APPLE_ID="sapoepsilon98@yandex.com"
TEAM_ID="NK28QT38A3"

echo "🔍 Searching for Developer ID certificate in keychain..."

# Check if certificate exists in keychain
if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "❌ Certificate not found in keychain"
    echo "🔍 Available certificates:"
    security find-certificate -p | openssl x509 -noout -subject 2>/dev/null || echo "No certificates found"
    exit 1
fi

echo "✅ Found certificate: $CERT_NAME"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
CERT_FILE="$TEMP_DIR/whispera-cert.p12"

echo "📦 Exporting certificate..."
echo "🔑 You'll be prompted for:"
echo "   1. Keychain password (if locked)"
echo "   2. New password for the p12 file (remember this!)"

# Export the certificate and private key
security export -t identities -f pkcs12 -o "$CERT_FILE" -k login.keychain

if [ ! -f "$CERT_FILE" ]; then
    echo "❌ Failed to export certificate"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✅ Certificate exported successfully"

# Convert to base64
echo "🔄 Converting to base64..."
BASE64_CERT=$(base64 -i "$CERT_FILE")

if [ -z "$BASE64_CERT" ]; then
    echo "❌ Failed to encode certificate"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "✅ Certificate encoded (${#BASE64_CERT} characters)"

# Prompt for certificate password
echo ""
read -s -p "🔑 Enter the password you used for the p12 export: " CERT_PASSWORD
echo ""

if [ -z "$CERT_PASSWORD" ]; then
    echo "❌ Password cannot be empty"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Generate a secure keychain password
KEYCHAIN_PASSWORD=$(openssl rand -base64 32)

echo "🚀 Setting up GitHub secrets..."

# Set all the secrets
gh secret set DEVELOPER_ID_P12 --body "$BASE64_CERT"
gh secret set DEVELOPER_ID_PASSWORD --body "$CERT_PASSWORD"
gh secret set KEYCHAIN_PASSWORD --body "$KEYCHAIN_PASSWORD"
gh secret set APPLE_ID --body "$APPLE_ID"
gh secret set TEAM_ID --body "$TEAM_ID"

echo "✅ GitHub secrets updated!"

# Clean up
rm -rf "$TEMP_DIR"

echo ""
echo "📋 Summary of configured secrets:"
gh secret list

echo ""
echo "🎯 Next steps:"
echo "1. Set APP_SPECIFIC_PASSWORD secret manually:"
echo "   - Go to https://appleid.apple.com"
echo "   - Generate an app-specific password"
echo "   - Run: gh secret set APP_SPECIFIC_PASSWORD --body 'your-app-password'"
echo ""
echo "2. Test the release workflow:"
echo "   git tag v1.0.9 && git push origin v1.0.9"