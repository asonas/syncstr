#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$PWD/.build/Syncstr.app"
mkdir -p "$app/Contents/MacOS" "$PWD/.build/module-cache"
xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  -o "$app/Contents/MacOS/Syncstr" Syncstr.swift Library.swift Navidrome.swift CredentialStore.swift Upload.swift UploadView.swift UploadSettingsView.swift SettingsView.swift
command cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "Apple Development: Yuya Fujiwara (55CYFEJC5B)" "$app"
printf '%s\n' "$app"
