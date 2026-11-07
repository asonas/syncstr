[CmdletBinding()]
param([string]$AndroidHome = $env:ANDROID_HOME)

$ErrorActionPreference = 'Stop'
if (!$AndroidHome) { throw 'Set ANDROID_HOME or pass -AndroidHome.' }
$ndk = Join-Path $AndroidHome 'ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $ndk 'aarch64-linux-android28-clang.cmd'
if (!(Test-Path $clang)) { throw 'Install NDK 28.2.13676358 for Windows.' }
Push-Location $PSScriptRoot
$previousLinker = $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
$previousAndroidHome = $env:ANDROID_HOME
try {
    $env:ANDROID_HOME = $AndroidHome
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $clang
    cargo build --locked --lib --no-default-features --target aarch64-linux-android
    if ($LASTEXITCODE) { throw 'ARM64 Rust build failed' }
    cargo build --locked --bin uniffi-bindgen
    if ($LASTEXITCODE) { throw 'Host generator build failed' }
    & ./target/debug/uniffi-bindgen.exe generate --library target/aarch64-linux-android/debug/libsyncstr_binding_probe.so --language kotlin --config android/uniffi.toml --out-dir generated/android --no-format
    if ($LASTEXITCODE) { throw 'Android binding generation failed' }
    New-Item -ItemType Directory -Force build/android-jni/arm64-v8a | Out-Null
    Copy-Item target/aarch64-linux-android/debug/libsyncstr_binding_probe.so build/android-jni/arm64-v8a/libsyncstr_binding_probe.so -Force
    & "$ndk/llvm-strip.exe" --strip-debug build/android-jni/arm64-v8a/libsyncstr_binding_probe.so
    if ($LASTEXITCODE) { throw 'Strip failed' }
    & ../../apps/android/gradlew.bat -p android assembleDebug assembleDebugAndroidTest lintDebug --console=plain
    if ($LASTEXITCODE) { throw 'Android APK build or Lint failed' }
    $apk = 'android/app/build/outputs/apk/debug/app-debug.apk'
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
    try {
        $entries = @($zip.Entries | Where-Object FullName -match '^lib/')
        if ($entries.Count -ne 2 -or !($entries.FullName -contains 'lib/arm64-v8a/libjnidispatch.so') -or !($entries.FullName -contains 'lib/arm64-v8a/libsyncstr_binding_probe.so')) {
            throw 'Unexpected native payload: require ARM64 Rust and JNA libraries only.'
        }
        New-Item -ItemType Directory -Force build/apk-inspection | Out-Null
        foreach ($entry in $entries) {
            $output = Join-Path (Resolve-Path build/apk-inspection) $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $output, $true)
            $headers = & "$ndk/llvm-readelf.exe" -h -l $output
            if ($LASTEXITCODE -or "$headers" -notmatch 'Machine:\s+AArch64') { throw 'Native library is not AArch64.' }
            foreach ($segment in @($headers | Where-Object { $_ -match '^\s*LOAD\s' })) {
                if ($segment -notmatch '0x4000\s*$') { throw 'Expected 16KB ELF segment alignment.' }
            }
        }
    } finally { $zip.Dispose() }
    $tools = Join-Path $AndroidHome 'build-tools/36.0.0'
    & "$tools/zipalign.exe" -c -P 16 4 $apk
    if ($LASTEXITCODE) { throw 'APK 16KB alignment check failed.' }
    foreach ($artifact in @($apk, 'android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk')) {
        & "$tools/apksigner.bat" verify $artifact
        if ($LASTEXITCODE) { throw 'APK signature verification failed.' }
        Get-FileHash $artifact -Algorithm SHA256
    }
} finally {
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $previousLinker
    $env:ANDROID_HOME = $previousAndroidHome
    Pop-Location
}
