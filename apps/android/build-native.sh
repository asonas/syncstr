#!/bin/sh
set -eu

android_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
ndk="$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin"
test -x "$ndk/aarch64-linux-android28-clang" || { echo "Install Android NDK 28.2.13676358 first" >&2; exit 1; }
export CC_aarch64_linux_android="$ndk/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$ndk/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
mise exec -- cargo build --manifest-path "$android_root/native/Cargo.toml" --locked --target aarch64-linux-android
mkdir -p "$android_root/app/src/main/jniLibs/arm64-v8a"
command cp "$android_root/native/target/aarch64-linux-android/debug/libsyncstr_android.so" "$android_root/app/src/main/jniLibs/arm64-v8a/"
"$ndk/llvm-strip" --strip-debug "$android_root/app/src/main/jniLibs/arm64-v8a/libsyncstr_android.so"
