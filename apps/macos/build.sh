#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$PWD/.build/Syncstr.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/.build/module-cache"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" ../ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" ../ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  -o "$app/Contents/MacOS/Syncstr" Syncstr.swift Library.swift Navidrome.swift CredentialStore.swift Upload.swift UploadView.swift UploadSettingsView.swift SettingsView.swift
command cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "Apple Development: Yuya Fujiwara (55CYFEJC5B)" "$app"
printf '%s\n' "$app"
