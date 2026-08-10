// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LicenseSeat",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12), .iOS(.v13), .tvOS(.v13), .watchOS(.v8)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LicenseSeat",
            targets: ["LicenseSeat"]),
    ],
    dependencies: [
        // Documentation Plugin (command plugin; no runtime impact)
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        // SwiftCrypto fallback for cross-platform Ed25519 verification
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LicenseSeat",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/LicenseSeatSDK",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LicenseSeatTests",
            dependencies: ["LicenseSeat"],
            path: "Tests/LicenseSeatSDKTests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
