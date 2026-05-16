// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FalMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FalMac", targets: ["FalMac"])
    ],
    targets: [
        .executableTarget(
            name: "FalMac",
            path: "Sources/FalMac"
        )
    ]
)
