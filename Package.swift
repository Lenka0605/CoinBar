// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoinBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CoinBar", path: "Sources/CoinBar")
    ]
)
