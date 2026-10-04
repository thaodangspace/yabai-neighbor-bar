// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YabaiNeighborBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "YabaiNeighborBar", targets: ["YabaiNeighborBar"])],
    targets: [
        .executableTarget(name: "YabaiNeighborBar", path: "Sources/YabaiNeighborBar", exclude: ["Resources/Info.plist"]),
        .testTarget(
            name: "YabaiNeighborBarTests",
            dependencies: ["YabaiNeighborBar"],
            resources: [.copy("Fixtures")]
        )
    ]
)
