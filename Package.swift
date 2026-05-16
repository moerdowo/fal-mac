// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FalMac",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FalMac", targets: ["FalMac"])
    ],
    targets: [
        .executableTarget(
            name: "FalMac",
            path: "Sources/FalMac",
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/AppIcon.png")
            ]
        )
    ]
)
