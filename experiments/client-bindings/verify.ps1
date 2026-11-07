$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$originalPath = $env:PATH
try {
    Get-Command cargo, rustc, java, swiftc | Select-Object Name, Source
    cargo --version
    rustc --version
    java -version
    swiftc --version
    cargo fmt --check
    if ($LASTEXITCODE) { throw 'Formatting failed' }
    cargo test --locked
    if ($LASTEXITCODE) { throw 'Rust test failed' }
    cargo clippy --locked --all-targets -- -D warnings
    if ($LASTEXITCODE) { throw 'Clippy failed' }
    cargo build --locked
    if ($LASTEXITCODE) { throw 'Rust build failed' }
    foreach ($language in @('kotlin', 'swift')) {
        & ./target/debug/uniffi-bindgen.exe generate --library target/debug/syncstr_binding_probe.dll --language $language --out-dir "generated/$language" --no-format
        if ($LASTEXITCODE) { throw "Generation failed: $language" }
    }
    & ../../apps/android/gradlew.bat -p . run --console=plain
    if ($LASTEXITCODE) { throw 'Kotlin probe failed' }
    New-Item -ItemType Directory -Force build | Out-Null
    swiftc -parse-as-library generated/swift/syncstr_binding_probe.swift swift/Probe.swift -I generated/swift -Xcc '-fmodule-map-file=generated/swift/syncstr_binding_probeFFI.modulemap' target/debug/syncstr_binding_probe.dll.lib -o build/swift-probe.exe
    if ($LASTEXITCODE) { throw 'Swift compilation failed' }
    $env:PATH = (Join-Path $PSScriptRoot 'target/debug') + ';' + $originalPath
    & ./build/swift-probe.exe
    if ($LASTEXITCODE) { throw 'Swift probe failed' }
} finally {
    $env:PATH = $originalPath
    Pop-Location
}
