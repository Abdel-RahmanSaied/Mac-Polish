// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacPolish",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacPolish", targets: ["MacPolish"])
    ],
    targets: [
        .executableTarget(
            name: "MacPolish",
            path: "Sources/MacPolish"
        )
    ]
)
