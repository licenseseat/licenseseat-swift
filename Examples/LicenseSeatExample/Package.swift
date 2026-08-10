// swift-tools-version: 5.10

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
        .package(name: "licenseseat-swift", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LicenseSeatExample",
            dependencies: [
                .product(name: "LicenseSeat", package: "licenseseat-swift")
            ]
        )
    ]
)
