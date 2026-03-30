// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MDViewer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "MDViewerCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "MDViewer",
            dependencies: ["MDViewerCore"]
        ),
        .testTarget(
            name: "MDViewerCoreTests",
            dependencies: [
                "MDViewerCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
