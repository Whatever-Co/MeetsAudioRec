#!/usr/bin/env bash
set -euo pipefail

# Configuration
DEVELOPER_ID="Developer ID Application: Whatever Co. (G5G54TCH8W)"
TEAM_ID="G5G54TCH8W"
KEYCHAIN_PROFILE="notarytool-profile"

APP_PATH="$1"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH"
  exit 1
fi

APP_NAME=$(basename "$APP_PATH" .app)
WORK_DIR=$(dirname "$APP_PATH")
ZIP_PATH="${WORK_DIR}/${APP_NAME}.zip"

echo "=== Signing $APP_NAME.app ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS_PATH="${SCRIPT_DIR}/../MeetsAudioRec/MeetsAudioRec.entitlements"

# Sign all nested components from inside out
# 1. Sign XPC services
find "$APP_PATH" -name "*.xpc" -type d | while read -r xpc; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$xpc"
done

# 2. Sign nested apps (e.g., Sparkle's Updater.app)
find "$APP_PATH/Contents/Frameworks" -name "*.app" -type d | while read -r nested_app; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$nested_app"
done

# 3. Sign standalone executables and dylibs inside frameworks
find "$APP_PATH/Contents/Frameworks" -type f \( -perm +111 -o -name "*.dylib" \) ! -name "*.plist" ! -name "*.h" ! -name "*.modulemap" ! -name "*.tbd" | while read -r item; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$item" 2>/dev/null || true
done

# 4. Sign frameworks themselves
find "$APP_PATH" -name "*.framework" -type d | while read -r fw; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$fw"
done

# 5. Sign the main app bundle with entitlements
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$DEVELOPER_ID" "$APP_PATH"

# Verify signature
codesign --verify --verbose "$APP_PATH"
echo "Signature verified."

echo "=== Creating ZIP for notarization ==="
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "=== Submitting for notarization ==="
# Note: First time setup requires:
# xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" --apple-id YOUR_APPLE_ID --team-id $TEAM_ID --password APP_SPECIFIC_PASSWORD

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "=== Stapling notarization ticket ==="
xcrun stapler staple "$APP_PATH"

# Verify stapled ticket
xcrun stapler validate "$APP_PATH"

# Clean up
rm -f "$ZIP_PATH"

echo "=== Notarization complete ==="
echo "$APP_PATH"
