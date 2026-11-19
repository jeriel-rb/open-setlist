// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetlistCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SetlistCore", targets: ["SetlistCore"]),
    ],
    targets: [
        .target(name: "SetlistCore"),
        .testTarget(
            name: "SetlistCoreTests",
            dependencies: ["SetlistCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
