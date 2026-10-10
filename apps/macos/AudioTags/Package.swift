// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "AudioTags",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "AudioTags", targets: ["AudioTags"])],
    dependencies: [.package(url: "https://github.com/sbooth/CXXTagLib", exact: "2.3.0")],
    targets: [.target(name: "AudioTags", dependencies: [.product(name: "taglib", package: "CXXTagLib")])],
    cxxLanguageStandard: .cxx17
)
