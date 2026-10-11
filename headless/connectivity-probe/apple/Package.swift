// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleConnectivityProbe",
    platforms: [.macOS("14.5")],
    dependencies: [.package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.1.0")],
    targets: [.executableTarget(name: "AppleConnectivityProbe", dependencies: [
        .product(name: "IrohLib", package: "iroh-ffi")
    ])]
)
