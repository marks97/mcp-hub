// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MCPHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MCPHub",
            path: "Sources"
        )
    ]
)
