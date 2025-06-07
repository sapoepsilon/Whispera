#!/bin/bash

# Whispera Release & Distribution Script Template
# Copy this file to release-distribute.sh and fill in your actual credentials

set -e  # Exit on any error

# Configuration
APP_NAME="Whispera"
SCHEME_NAME="Whispera"
BUILD_CONFIGURATION="Release"
ARCHIVE_PATH="./build/Release/${APP_NAME}.xcarchive"
EXPORT_PATH="./build/Release"
DIST_PATH="./dist"

# Code signing configuration - REPLACE WITH YOUR ACTUAL VALUES
DEVELOPER_ID="Developer ID Application: Your Name (YOUR_TEAM_ID)"
APPLE_ID="your-apple-id@example.com"
APP_SPECIFIC_PASSWORD="your-app-specific-password"
TEAM_ID="YOUR_TEAM_ID"

# ... rest of the script is the same as release-distribute.sh