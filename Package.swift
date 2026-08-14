// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LocalRig",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LocalRig", targets: ["LocalRig"]),
    ],
    targets: [
        .executableTarget(
            name: "LocalRig",
            path: "Sources/LocalRig"
        ),
        .testTarget(
            name: "LocalRigTests",
            dependencies: ["LocalRig"],
            path: "Tests/LocalRigTests"
        ),
    ]
)
