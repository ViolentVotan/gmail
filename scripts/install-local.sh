#!/bin/bash
set -euo pipefail

# Build Vik Release and install to /Applications
# Uses Xcode's automatic signing with the configured team/certificate.

PROJECT="Vik.xcodeproj"
SCHEME="Vik"
APP_NAME="Vik"
DERIVED_DATA="build/release"
APP_SRC="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_DST="/Applications/$APP_NAME.app"

echo "Building $APP_NAME (Release)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  build 2>&1 | tail -5

if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: Build product not found at $APP_SRC"
  exit 1
fi

# Verify signing before install
echo ""
echo "Verifying code signature..."
TEAM=$(codesign -dvvv "$APP_SRC" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2)
AUTHORITY=$(codesign -dvvv "$APP_SRC" 2>&1 | grep "Authority=Apple" | head -1)

if [ "$TEAM" = "not set" ] || [ -z "$TEAM" ]; then
  echo "ERROR: App is not properly signed (no team identifier)."
  echo "Check Xcode Signing & Capabilities: Team must be set."
  exit 1
fi

codesign --verify --deep --strict "$APP_SRC"
echo "Signed: $AUTHORITY (Team: $TEAM)"

# Install
echo ""
if [ -d "$APP_DST" ]; then
  echo "Removing existing $APP_DST..."
  rm -r "$APP_DST"
fi

cp -R "$APP_SRC" "$APP_DST"
echo "Installed to $APP_DST"

# Final verification
codesign --verify --deep --strict "$APP_DST"
echo "Installation verified. Launch Vik from /Applications."
