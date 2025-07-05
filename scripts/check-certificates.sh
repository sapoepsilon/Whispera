#!/bin/bash

echo "🔍 Checking available certificates in your keychain..."
echo ""

echo "📋 All certificates in login keychain:"
security find-certificate -a login.keychain | grep -A1 -B1 "labl" | grep -E "(labl|Developer|Apple)"

echo ""
echo "📋 All identities in login keychain:"
security find-identity -v login.keychain

echo ""
echo "📋 Code signing identities specifically:"
security find-identity -v -p codesigning login.keychain

echo ""
echo "🎯 Looking for Developer ID certificates..."
security find-identity -v login.keychain | grep -i "developer id"

echo ""
echo "🏢 Looking for 3rd Party Mac Developer certificates..."
security find-identity -v login.keychain | grep -i "3rd party"

echo ""
echo "🍎 Looking for Apple Development certificates..."
security find-identity -v login.keychain | grep -i "apple development"

echo ""
echo "📝 Certificate types you need for different purposes:"
echo "   - Developer ID Application: For distributing outside Mac App Store (what we need)"
echo "   - Apple Development: For development and testing"
echo "   - 3rd Party Mac Developer Application: For Mac App Store submission"
echo "   - 3rd Party Mac Developer Installer: For Mac App Store installer packages"

echo ""
echo "💡 To get a Developer ID Application certificate:"
echo "   1. Go to https://developer.apple.com/account/resources/certificates/list"
echo "   2. Click the + button to create a new certificate"
echo "   3. Select 'Developer ID Application' under 'Production'"
echo "   4. Follow the prompts to create and download the certificate"
echo "   5. Double-click the downloaded certificate to install it in your keychain"