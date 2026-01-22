// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StressTest",
    platforms: [.macOS(.v12)],
    dependencies: [
        // Use published SDK from GitHub
        // For local development, change to: .package(path: "..")
        .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.3.1")
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
