// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Presence",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Presence",
            targets: ["Presence"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Presence"
        )
    ]
)