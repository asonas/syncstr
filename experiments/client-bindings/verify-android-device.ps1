[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeviceSerial,
    [string]$AndroidHome = $env:ANDROID_HOME
)

$ErrorActionPreference = 'Stop'
if (!$AndroidHome) { throw 'Set ANDROID_HOME or pass -AndroidHome.' }
$adb = Join-Path $AndroidHome 'platform-tools/adb.exe'
$buildTools = Join-Path $AndroidHome 'build-tools/36.0.0'
Push-Location $PSScriptRoot
try {
    $state = & $adb -s $DeviceSerial get-state
    if ($LASTEXITCODE -or "$state".Trim() -ne 'device') { throw 'Selected device is not online and authorized.' }
    $abis = & $adb -s $DeviceSerial shell getprop ro.product.cpu.abilist
    if ($LASTEXITCODE -or "$abis" -notmatch 'arm64-v8a') { throw 'Selected device does not support ARM64.' }
    $qemu = & $adb -s $DeviceSerial shell getprop ro.kernel.qemu
    if ("$qemu".Trim() -eq '1') { throw 'Select a physical device for physical-device acceptance.' }
    $apk = 'android/app/build/outputs/apk/debug/app-debug.apk'
    $tests = 'android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
    foreach ($artifact in @($apk, $tests)) {
        & "$buildTools/apksigner.bat" verify --print-certs $artifact
        if ($LASTEXITCODE) { throw 'APK signature verification failed.' }
        Get-FileHash $artifact -Algorithm SHA256
    }
    $badging = & "$buildTools/aapt.exe" dump badging $apk
    if ($LASTEXITCODE -or "$badging" -notmatch "package: name='as.ason.syncstr.bindingprobe'") { throw 'Unexpected APK identity.' }
    foreach ($artifact in @($apk, $tests)) {
        & $adb -s $DeviceSerial install -r $artifact
        if ($LASTEXITCODE) { throw 'Install failed; do not uninstall to bypass a signature mismatch.' }
    }
    New-Item -ItemType Directory -Force build/android-evidence | Out-Null
    $result = & $adb -s $DeviceSerial shell am instrument -w -r 'as.ason.syncstr.bindingprobe.test/as.ason.syncstr.bindingprobe.BindingTest'
    $result | Set-Content build/android-evidence/instrumentation.txt
    $result
    if ($LASTEXITCODE -or "$result" -notmatch 'INSTRUMENTATION_CODE: -1' -or "$result" -notmatch 'PASS ARM64:' -or "$result" -match 'FAIL ARM64:') {
        throw 'Instrumentation did not report successful binding checks.'
    }
    $launch = & $adb -s $DeviceSerial shell am start -W -n 'as.ason.syncstr.bindingprobe/.ProbeActivity'
    $launch
    if ($LASTEXITCODE -or "$launch" -notmatch 'Status: ok') { throw 'Activity launch failed.' }
    $appPid = (& $adb -s $DeviceSerial shell pidof as.ason.syncstr.bindingprobe).Trim()
    if (!$appPid) { throw 'Probe process did not remain running.' }
    & $adb -s $DeviceSerial logcat -d --pid=$appPid | Set-Content build/android-evidence/logcat.txt
    & $adb -s $DeviceSerial shell screencap -p /data/local/tmp/syncstr-binding-probe.png
    if ($LASTEXITCODE) { throw 'Screenshot capture failed.' }
    & $adb -s $DeviceSerial pull /data/local/tmp/syncstr-binding-probe.png build/android-evidence/screenshot.png
    if ($LASTEXITCODE) { throw 'Screenshot retrieval failed.' }
    & $adb -s $DeviceSerial shell rm /data/local/tmp/syncstr-binding-probe.png
} finally {
    Pop-Location
}
