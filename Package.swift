// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MediaStream",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MediaStream",
            targets: ["MediaStream"]
        ),
    ],
    dependencies: [
        // No external dependencies - uses native AVFoundation + WKWebView for video support
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MediaStream",
            dependencies: [],
            resources: [
                // UI strings in the Big 8 (zh-Hans, ja, de, fr, es, ko, pt-BR, it).
                // Every user-facing string resolves from `Bundle.module`.
                .process("Resources/Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "MediaStreamTests",
            dependencies: ["MediaStream"]
        ),
    ]
)
