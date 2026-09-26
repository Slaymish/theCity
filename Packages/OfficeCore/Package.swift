// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OfficeCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "OfficeCore", targets: ["OfficeCore"])],
    targets: [
        .target(name: "OfficeCore"),
        .testTarget(name: "OfficeCoreTests", dependencies: ["OfficeCore"]),
    ]
)
