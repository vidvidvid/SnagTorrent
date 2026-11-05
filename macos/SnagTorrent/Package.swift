// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnagTorrent",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SnagTorrent",
            path: "Sources/SnagTorrent"
        ),
        .testTarget(
            name: "SnagTorrentTests",
            dependencies: ["SnagTorrent"],
            path: "Tests/SnagTorrentTests"
        ),
    ]
)
