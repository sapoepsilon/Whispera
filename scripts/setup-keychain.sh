#!/bin/bash

# Whispera CI Keychain Setup Script
# Securely sets up code signing certificates in CI environment

set -e

KEYCHAIN_NAME="whispera-signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

echo "🔐 Setting up secure keychain for code signing..."

# Check required environment variables
if [ -z "$DEVELOPER_ID_P12" ]; then
    echo "❌ Error: DEVELOPER_ID_P12 environment variable not set"
    exit 1
fi

if [ -z "$DEVELOPER_ID_PASSWORD" ]; then
    echo "❌ Error: DEVELOPER_ID_PASSWORD environment variable not set"
    exit 1
fi

if [ -z "$KEYCHAIN_PASSWORD" ]; then
    echo "❌ Error: KEYCHAIN_PASSWORD environment variable not set"
    exit 1
fi

# Clean up any existing keychain
echo "🧹 Cleaning up existing keychains..."
security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true

# Create temporary certificate file
CERT_FILE="$(mktemp -t whispera-cert).p12"
echo "📜 Decoding certificate..."
echo "$DEVELOPER_ID_P12" | base64 --decode > "$CERT_FILE"

# Verify certificate file was created successfully
if [ ! -f "$CERT_FILE" ] || [ ! -s "$CERT_FILE" ]; then
    echo "❌ Error: Failed to decode certificate"
    rm -f "$CERT_FILE"
    exit 1
fi

# Create new keychain
echo "🔑 Creating new keychain..."
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Set keychain settings
echo "⚙️ Configuring keychain settings..."
security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"  # Lock after 6 hours
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Import certificate
echo "📥 Importing signing certificate..."
security import "$CERT_FILE" \
    -k "$KEYCHAIN_NAME" \
    -P "$DEVELOPER_ID_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Set key partition list (required for macOS 10.12+)
echo "🔧 Setting key partition list..."
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_NAME" >/dev/null 2>&1 || true

# Add to search list
echo "🔍 Adding keychain to search list..."
security list-keychains -s "$KEYCHAIN_NAME" login.keychain

# Verify certificate is available
echo "✅ Verifying certificate installation..."

# First, show all available identities for debugging
echo "📋 All available identities in keychain:"
security find-identity -v -p codesigning "$KEYCHAIN_NAME"

# Count Developer ID certificates (more flexible pattern)
CERT_COUNT=$(security find-identity -v -p codesigning "$KEYCHAIN_NAME" | grep -c "Developer ID" || echo "0")

if [ "$CERT_COUNT" -eq 0 ]; then
    echo "❌ Error: No Developer ID certificates found in keychain"
    echo "Available certificates:"
    security find-identity -v "$KEYCHAIN_NAME"
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
    rm -f "$CERT_FILE"
    exit 1
fi

echo "🎯 Found $CERT_COUNT Developer ID certificate(s)"

# Show available identities (without private keys)
echo "📋 Available signing identities:"
security find-identity -v -p codesigning "$KEYCHAIN_NAME" | grep "Developer ID" || security find-identity -v -p codesigning "$KEYCHAIN_NAME"

# Clean up certificate file
rm -f "$CERT_FILE"

echo "✅ Keychain setup complete!"
echo "🔑 Keychain: $KEYCHAIN_NAME"
echo "⏰ Auto-lock: 6 hours"

# Set environment variable for subsequent steps
echo "SIGNING_KEYCHAIN=$KEYCHAIN_NAME" >> "$GITHUB_ENV"