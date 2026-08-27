// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LayerBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LayerBar", path: "Sources/LayerBar")
    ]
)
