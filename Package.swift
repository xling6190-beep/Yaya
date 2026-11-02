// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yaya",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Yaya",
            path: "Sources/SwivelX"
        )
    ]
)
