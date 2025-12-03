#!/bin/bash

# Sparkle EdDSA Key Generation Script
# This script generates EdDSA keys for Sparkle update signing
# Run this ONCE and save the public key to Info.plist

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Sparkle EdDSA Key Generator"
echo "==========================="
echo ""

# Check if Sparkle tools exist in the build directory
SPARKLE_TOOLS_PATH="$PROJECT_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [ ! -d "$SPARKLE_TOOLS_PATH" ]; then
    echo "Sparkle tools not found at: $SPARKLE_TOOLS_PATH"
    echo ""
    echo "First, build the project in Xcode to download the Sparkle package."
    echo "Then run this script again."
    echo ""
    echo "Alternatively, download Sparkle manually from:"
    echo "https://github.com/sparkle-project/Sparkle/releases"
    exit 1
fi

GENERATE_KEYS="$SPARKLE_TOOLS_PATH/generate_keys"

if [ ! -f "$GENERATE_KEYS" ]; then
    echo "generate_keys tool not found at: $GENERATE_KEYS"
    exit 1
fi

echo "Found Sparkle tools at: $SPARKLE_TOOLS_PATH"
echo ""

# Check if key already exists in Keychain
if security find-generic-password -s "Sparkle Private Key" &>/dev/null; then
    echo "A Sparkle private key already exists in your Keychain."
    echo ""
    echo "To export the existing key:"
    echo "  $GENERATE_KEYS -x sparkle_private_key"
    echo ""
    echo "To view the public key (for Info.plist):"
    echo "  $GENERATE_KEYS -p"
    echo ""
    read -p "Do you want to view the existing public key? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        "$GENERATE_KEYS" -p
    fi
    exit 0
fi

echo "Generating new EdDSA key pair..."
echo ""
"$GENERATE_KEYS"

echo ""
echo "IMPORTANT: Copy the SUPublicEDKey value above and add it to Info.plist"
echo ""
echo "The private key has been saved to your macOS Keychain."
echo "For CI/CD, export the key using:"
echo "  $GENERATE_KEYS -x sparkle_private_key"
echo ""
