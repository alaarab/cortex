// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhrenKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhrenKit", targets: ["PhrenKit"]),
    ],
    targets: [
        .target(name: "PhrenKit"),
        .testTarget(
            name: "PhrenKitTests",
            dependencies: ["PhrenKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
