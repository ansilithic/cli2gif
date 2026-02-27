// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cli2gif",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "cli2gif",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
