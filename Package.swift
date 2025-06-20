// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LicenseSeatSDK",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12), .iOS(.v13), .tvOS(.v13), .watchOS(.v8)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LicenseSeatSDK",
            targets: ["LicenseSeatSDK"]),
    ],
    dependencies: [
        // Documentation Plugin (command plugin; no runtime impact)
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
        // SwiftCrypto fallback for cross-platform Ed25519 verification
        .package(url: "https://github.com/apple/swift-crypto.git", from: "2.6.0"),
        // Future runtime dependencies (e.g., networking) will be added here.
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LicenseSeatSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            resources: [
                // Place bundled assets or JSON fixtures here, if needed.
            ]
        ),
        .testTarget(
            name: "LicenseSeatSDKTests",
            dependencies: ["LicenseSeatSDK"]
        ),
    ]
)
