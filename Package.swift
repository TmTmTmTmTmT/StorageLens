// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageLens",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .executable(name: "StorageLens", targets: ["StorageLensApp"]),
    ],
    targets: [
        .target(name: "StorageCore"),
        .executableTarget(name: "StorageLensApp", dependencies: ["StorageCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
    ],
    swiftLanguageModes: [.v6]
)
