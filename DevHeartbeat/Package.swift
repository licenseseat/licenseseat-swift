// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevHeartbeat",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/licenseseat/licenseseat-swift.git", from: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "DevHeartbeat",
            dependencies: [
                .product(name: "LicenseSeat", package: "licenseseat-swift")
            ]
        )
    ]
)
