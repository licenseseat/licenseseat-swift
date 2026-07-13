// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StressTest",
    platforms: [.macOS(.v12)],
    dependencies: [
        // This is a repository-local release harness: always exercise the
        // checked-out SDK rather than a previously published tag.
        .package(name: "licenseseat-swift", path: "..")
    ],
    targets: [
        .executableTarget(
            name: "StressTest",
            dependencies: [
                .product(name: "LicenseSeat", package: "licenseseat-swift")
            ]
        )
    ]
)
