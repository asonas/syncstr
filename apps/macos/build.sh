#!/bin/sh
set -eu
: "${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to your development signing identity}"
cd "$(dirname "$0")"
app="$PWD/.build/Syncstr.app"
mkdir -p "$PWD/.build"
mise exec -- xcodegen generate --spec ../ios/project.yml
xcodebuild -project ../ios/Syncstr.xcodeproj -scheme SyncstrMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$PWD/.build/DerivedData" \
  CONFIGURATION_BUILD_DIR="$PWD/.build" PRODUCT_BUNDLE_IDENTIFIER=as.ason.syncstr.first-listen \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  CODE_SIGN_ENTITLEMENTS= ENABLE_APP_SANDBOX=NO build > "$PWD/.build/build.log" 2>&1
printf '%s\n' "$app"
