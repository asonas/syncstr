[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$AndroidHome = $env:ANDROID_HOME,
    [string]$NdkVersion = '28.2.13676358',
    [string]$RustToolchain = '1.99.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$androidRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($AndroidHome)) {
    throw 'Set ANDROID_HOME or pass -AndroidHome with the Android SDK directory.'
}

$androidHomePath = [System.IO.Path]::GetFullPath($AndroidHome)
$toolchainBin = Join-Path $androidHomePath "ndk\$NdkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin"
$clang = Join-Path $toolchainBin 'aarch64-linux-android28-clang.cmd'
if (-not (Test-Path -LiteralPath $clang -PathType Leaf)) {
    $clang = Join-Path $toolchainBin 'aarch64-linux-android28-clang.exe'
}
$archiver = Join-Path $toolchainBin 'llvm-ar.exe'
$strip = Join-Path $toolchainBin 'llvm-strip.exe'

foreach ($tool in @($clang, $archiver, $strip)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Android NDK $NdkVersion tool not found: $tool"
    }
}

if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw 'rustup was not found on PATH. Install the verified Rust toolchain first.'
}

$target = 'aarch64-linux-android'
$manifest = Join-Path $androidRoot 'native\Cargo.toml'
$profileArgument = if ($Configuration -eq 'Release') { '--release' } else { $null }
$profileDirectory = $Configuration.ToLowerInvariant()
$nativeOutput = Join-Path $androidRoot "native\target\$target\$profileDirectory\libsyncstr_android.so"
$jniDirectory = Join-Path $androidRoot 'app\src\main\jniLibs\arm64-v8a'
$jniOutput = Join-Path $jniDirectory 'libsyncstr_android.so'

$previousCc = $env:CC_aarch64_linux_android
$previousAr = $env:AR_aarch64_linux_android
$previousLinker = $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
try {
    $env:CC_aarch64_linux_android = $clang
    $env:AR_aarch64_linux_android = $archiver
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $clang

    $cargoArguments = @('build', '--manifest-path', $manifest, '--locked', '--target', $target)
    if ($profileArgument) {
        $cargoArguments += $profileArgument
    }
    & rustup run $RustToolchain cargo @cargoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
}
finally {
    $env:CC_aarch64_linux_android = $previousCc
    $env:AR_aarch64_linux_android = $previousAr
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $previousLinker
}

if (-not (Test-Path -LiteralPath $nativeOutput -PathType Leaf)) {
    throw "Cargo output was not found: $nativeOutput"
}

New-Item -ItemType Directory -Path $jniDirectory -Force | Out-Null
Copy-Item -LiteralPath $nativeOutput -Destination $jniOutput -Force
& $strip --strip-debug $jniOutput
if ($LASTEXITCODE -ne 0) {
    throw "llvm-strip failed with exit code $LASTEXITCODE"
}

Write-Host "Prepared $jniOutput"
