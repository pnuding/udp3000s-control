// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UDP3000SControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UDP3000SControl",
            path: "Sources/UDP3000SControl"
        )
    ]
)
