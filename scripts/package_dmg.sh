#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"

APP_NAME="MeetsAudioRec"
VOL_NAME="MeetsAudioRec"
DMG_NAME="MeetsAudioRec"

DMG_ROOT="${BUILD_DIR}/dmg-root"
OUT_DMG="${BUILD_DIR}/${DMG_NAME}.dmg"

rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"

echo "=== Building Release ==="
"${ROOT_DIR}/scripts/build.sh" Release

APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}.app"

echo "=== Notarizing app ==="
"${ROOT_DIR}/scripts/notarize.sh" "${APP_PATH}"

cp -R "${APP_PATH}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"

echo "=== Creating DMG ==="
rm -f "${OUT_DMG}"
# Use writable image + convert approach to avoid hdiutil -srcfolder issues
# with signed app bundles containing embedded frameworks
TEMP_DMG="${BUILD_DIR}/MeetsAudioRec_temp.dmg"
rm -f "${TEMP_DMG}"
hdiutil create -size 200m -fs HFS+ -volname "${VOL_NAME}" "${TEMP_DMG}"
hdiutil attach "${TEMP_DMG}" -noverify -mountpoint "/Volumes/${VOL_NAME}"
cp -R "${DMG_ROOT}/${APP_NAME}.app" "/Volumes/${VOL_NAME}/"
ln -s /Applications "/Volumes/${VOL_NAME}/Applications"
hdiutil detach "/Volumes/${VOL_NAME}"
hdiutil convert "${TEMP_DMG}" -format UDZO -o "${OUT_DMG}"
rm -f "${TEMP_DMG}"

echo "=== Notarizing DMG ==="
DEVELOPER_ID="Developer ID Application: Whatever Co. (G5G54TCH8W)"
KEYCHAIN_PROFILE="notarytool-profile"

codesign --force --sign "$DEVELOPER_ID" "${OUT_DMG}"

xcrun notarytool submit "${OUT_DMG}" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "${OUT_DMG}"

echo "=== Done ==="
echo "Created notarized DMG:"
echo "${OUT_DMG}"
