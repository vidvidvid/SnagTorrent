// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnagTorrent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnagTorrent",
            path: "Sources/SnagTorrent"
        )
    ]
)
