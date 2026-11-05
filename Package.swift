// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LockWall",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "LockWall", path: "Sources/LockWall")],
    swiftLanguageModes: [.v5]
)
