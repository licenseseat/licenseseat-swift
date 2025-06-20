// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "LicenseSeatExample",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .executable(name: "LicenseSeatExample", targets: ["LicenseSeatExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LicenseSeatExample",
            dependencies: [
                .product(name: "LicenseSeatSDK", package: "licenseseat-swift")
            ]
        )
    ]
) 