#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Atoll.app"
INSTALLED_APP="/Applications/Atoll.app"
STAGING_APP="/Applications/.Atoll.installing.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
LOCAL_ENTITLEMENTS="$ROOT_DIR/Scripts/AtollLocal.entitlements"
LOCAL_SIGNING_IDENTITY="Ice Local Code Signing"

xcodebuild \
  -project "$ROOT_DIR/DynamicIsland.xcodeproj" \
  -scheme DynamicIsland \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  CODE_SIGNING_ALLOWED=NO

pkill -x Atoll 2>/dev/null || true
while IFS= read -r adapter_pid; do
  kill "$adapter_pid" 2>/dev/null || true
done < <(pgrep -f '^/usr/bin/perl .*mediaremote-adapter\.pl ' || true)

rm -rf "$STAGING_APP"
/usr/bin/ditto "$BUILT_APP" "$STAGING_APP"

if security find-identity -v -p codesigning | grep -Fq "\"$LOCAL_SIGNING_IDENTITY\""; then
  SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
else
  SIGNING_IDENTITY="-"
fi

codesign --force --sign "$SIGNING_IDENTITY" "$STAGING_APP/Contents/Frameworks/Lottie.framework"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGING_APP/Contents/Resources/MediaRemoteAdapter.framework"
codesign --force --options runtime --entitlements "$LOCAL_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

rm -rf "$INSTALLED_APP"
mv "$STAGING_APP" "$INSTALLED_APP"

# Remove all build-product registrations and apps so only /Applications remains.
for duplicate_app in \
  "$DERIVED_DATA/Build/Products/Debug/Atoll.app" \
  "$DERIVED_DATA/Build/Products/Release/Atoll.app" \
  "$ROOT_DIR/build/VerificationDerivedData/Build/Products/Debug/Atoll.app"; do
  "$LSREGISTER" -u "$duplicate_app" 2>/dev/null || true
  rm -rf "$duplicate_app"
done

"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
tccutil reset Accessibility com.Ebullioscopic.Atoll.dev 2>/dev/null || true

open "$INSTALLED_APP"

USAGE_PLUGIN="$HOME/Desktop/code/AtollCodexUsage/build/AtollCodexUsage.app"
if [[ -d "$USAGE_PLUGIN" ]]; then
  pkill -x AtollCodexUsage 2>/dev/null || true
  open "$USAGE_PLUGIN"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist")
echo "Installed Atoll $VERSION ($BUILD) at $INSTALLED_APP"
