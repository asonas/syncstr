#!/bin/sh
set -eu

android_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
case "$(uname -s):$(uname -m)" in
    Darwin:arm64|Darwin:x86_64) ndk_host=darwin-x86_64 ;;
    Linux:x86_64) ndk_host=linux-x86_64 ;;
    *) echo "Unsupported Android NDK build host: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
ndk="$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/$ndk_host/bin"
test -x "$ndk/aarch64-linux-android28-clang" || { echo "Install Android NDK 28.2.13676358 first" >&2; exit 1; }
export CC_aarch64_linux_android="$ndk/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$ndk/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
mise exec -- cargo build --manifest-path "$android_root/native/Cargo.toml" --locked --target aarch64-linux-android
mkdir -p "$android_root/app/src/main/jniLibs/arm64-v8a"
command cp "$android_root/native/target/aarch64-linux-android/debug/libsyncstr_android.so" "$android_root/app/src/main/jniLibs/arm64-v8a/"
"$ndk/llvm-strip" --strip-debug "$android_root/app/src/main/jniLibs/arm64-v8a/libsyncstr_android.so"
