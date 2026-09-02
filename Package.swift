// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "resto",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "resto", targets: ["resto"])],
    targets: [.executableTarget(name: "resto")]
)
