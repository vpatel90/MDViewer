// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDViewer",
    platforms: [.macOS(.v14)],
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
            dependencies: ["MDViewerCore"]
        )
    ]
)
