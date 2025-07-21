#!/bin/bash

# Local test script for keychain setup
set -e

echo "🧪 Testing keychain setup locally..."

# Export the certificate with empty password for testing
TEMP_CERT="/tmp/test-whispera-cert.p12"
echo "📦 Exporting certificate for testing..."
security export -t identities -f pkcs12 -k login.keychain -o "$TEMP_CERT" -P "" "Developer ID Application: Ismatulla Mansurov (NK28QT38A3)"

# Convert to base64
echo "🔄 Converting to base64..."
BASE64_CERT=$(base64 -i "$TEMP_CERT")

# Set up test environment variables
export DEVELOPER_ID_P12="$BASE64_CERT"
export DEVELOPER_ID_PASSWORD=""  # Empty password
export KEYCHAIN_PASSWORD="test-password-123"

echo "✅ Test environment variables set"
echo "   DEVELOPER_ID_P12 length: ${#DEVELOPER_ID_P12} characters"
echo "   DEVELOPER_ID_PASSWORD: '${DEVELOPER_ID_PASSWORD}'"
echo "   KEYCHAIN_PASSWORD: set"

# Run the setup script
echo ""
echo "🚀 Running setup-keychain.sh script..."
./scripts/setup-keychain.sh

echo ""
echo "🎯 Test completed! Check the output above for any errors."

# Clean up
rm -f "$TEMP_CERT"

# Check if keychain was created successfully
if security list-keychains | grep -q "whispera-signing.keychain-db"; then
    echo "✅ Keychain created successfully"
    
    # Show what's in the keychain
    echo "📋 Contents of test keychain:"
    security find-identity -v whispera-signing.keychain-db
    
    # Clean up test keychain
    echo "🧹 Cleaning up test keychain..."
    security delete-keychain whispera-signing.keychain-db 2>/dev/null || true
else
    echo "❌ Keychain was not created"
fi