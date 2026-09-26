#!/bin/bash

# Whispera Release & Distribution Script Template
# Only the settings of a private, gitignored release-distribute.sh. The script body is not
# in the repository; scripts/README.md lists the steps it runs and how to release by hand
# with release-distribute-ci.sh instead.

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

# The steps (archive, export, sign, notarize, staple, DMG) follow release-distribute-ci.sh.