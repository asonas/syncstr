#!/bin/sh
set -eu

android_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
key=${SYNCSTR_ANDROID_DEV_KEYSTORE:-"$HOME/.local/share/syncstr/android-dev/development.keystore"}
test -f "$key" || { echo "Provision the stable development keystore before building: $key" >&2; exit 1; }
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}
sh "$android_root/build-native.sh"
mise exec java@temurin-21.0.12+101.0.LTS gradle@8.13 -- \
    gradle -p "$android_root" --no-daemon --max-workers=2 \
    assembleDebug assembleDebugAndroidTest lintDebug
